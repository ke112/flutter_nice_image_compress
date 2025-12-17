import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class ImageCompressorResult {
  /// 压缩后文件
  final File file;

  /// 压缩后大小，单位：字节
  final int bytes;

  /// 压缩后质量，0-100
  final int qualityUsed;

  /// 压缩后图片信息
  final SizeInfo sizeInfo;

  ImageCompressorResult({required this.file, required this.bytes, required this.qualityUsed, required this.sizeInfo});
}

class SizeInfo {
  final int? width;
  final int? height;
  const SizeInfo({this.width, this.height});
}

class ImageCompressorOptions {
  /// 目标大小，单位：KB
  final int targetSizeInKB;

  /// 初始质量，0-100
  final int initialQuality;

  /// 最小质量，0-100
  final int minQuality;

  /// 质量步长，0-100
  final int step;

  /// 最大宽度，0-无限
  final int? maxWidth;

  /// 最大高度，0-无限
  final int? maxHeight;

  /// 压缩格式
  final CompressFormat format;

  /// EXIF 信息：默认情况下，压缩后的图片不会保留原始图片的 EXIF 信息（如拍摄参数、GPS 位置等）。
  /// 如果需要保留，可以将 keepExif 参数设为 true，但请注意此选项仅对 JPG 格式有效，且不会保留方向信息
  final bool keepExif;

  /// 早停命中带下界比例，命中条件：[earlyStopRatio * target, target]
  final double earlyStopRatio;

  /// 小偏差快速路径触发因子：原图 ≤ nearTargetFactor * target 时启用
  final double nearTargetFactor;

  /// 小偏差路径下的最低质量下限
  final int preferredMinQuality;

  /// 每个维度/区间的最大尝试次数
  final int maxAttemptsPerDim;

  /// 全流程的最大尝试次数
  final int maxTotalTrials;

  const ImageCompressorOptions({
    required this.targetSizeInKB,
    this.initialQuality = 92,
    this.minQuality = 40,
    this.step = 4,
    this.maxWidth,
    this.maxHeight,
    this.format = CompressFormat.jpeg,
    this.keepExif = false,
    this.earlyStopRatio = 0.95,
    this.nearTargetFactor = 1.2,
    this.preferredMinQuality = 80,
    this.maxAttemptsPerDim = 5,
    this.maxTotalTrials = 24,
  }) : assert(targetSizeInKB > 0),
       assert(initialQuality <= 100 && initialQuality > 0),
       assert(minQuality > 0 && minQuality <= initialQuality),
       assert(step > 0),
       assert(earlyStopRatio > 0 && earlyStopRatio <= 1.0),
       assert(nearTargetFactor >= 1.0),
       assert(preferredMinQuality > 0 && preferredMinQuality <= 100),
       assert(maxAttemptsPerDim > 0),
       assert(maxTotalTrials > 0);
}

class _Semaphore {
  _Semaphore(int permits) : _maxPermits = permits, _permits = permits;

  final int _maxPermits;
  int _permits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final Completer<void> c = Completer<void>();
    _waiters.addLast(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final Completer<void> c = _waiters.removeFirst();
      if (!c.isCompleted) c.complete();
    } else if (_permits < _maxPermits) {
      _permits++;
    }
  }
}

class ImageCompressorService {
  static final _Semaphore _sem = _Semaphore(_defaultConcurrency());

  static int _defaultConcurrency() {
    int cores = Platform.numberOfProcessors;
    int p = cores > 1 ? cores - 1 : 1;
    if (p > 3) p = 3;
    if (p < 1) p = 1;
    return p;
  }

  static bool _isInEarlyStopBand(int size, int target, double ratio) {
    return size <= target && size >= (target * ratio).floor();
  }

  /// Compress image to target size in KB with iterative quality reduction and optional downscale.
  static Future<ImageCompressorResult> compressToTarget(
    File sourceFile, {
    required ImageCompressorOptions options,
  }) async {
    await _sem.acquire();
    try {
      final int targetBytes = options.targetSizeInKB * 1024;
      // Disable EXIF when target is very small to reduce size and avoid native issues (reserved for native path)
      // Note: current path uses pure Dart; keep variable for future native usage if needed.
      // final bool effectiveKeepExif = options.keepExif && targetBytes >= 300 * 1024;
      // Safety: if provided target is unrealistically small (< 10KB), cap it to 10KB to avoid native crashes
      final int safeTargetBytes = targetBytes < 10 * 1024 ? 10 * 1024 : targetBytes;

      // Fast path: if already <= target, return original copy to temp dir
      final int originalBytes = await sourceFile.length();
      if (originalBytes <= targetBytes) {
        final File copied = await _copyToTemp(sourceFile);
        return ImageCompressorResult(file: copied, bytes: originalBytes, qualityUsed: 100, sizeInfo: const SizeInfo());
      }

      // Near-target fast path: prefer higher min quality, minimal attempts, early stop in band
      final bool isNearTarget = originalBytes <= (safeTargetBytes * options.nearTargetFactor).floor();
      if (isNearTarget) {
        final int nearMinQ =
            options.preferredMinQuality > options.minQuality ? options.preferredMinQuality : options.minQuality;
        // Native fast path with higher min quality
        final Map<String, dynamic>? nativeNear = await _nativeFastQualitySearch(
          sourceFile.path,
          safeTargetBytes,
          options.initialQuality,
          nearMinQ,
          options.format,
          options.keepExif,
          options.earlyStopRatio,
        );
        if (nativeNear != null) {
          final Uint8List outBytes = nativeNear['bytes'] as Uint8List;
          final int quality = nativeNear['quality'] as int;
          final File outFile = await _writeBytesToTemp(outBytes);
          return ImageCompressorResult(
            file: outFile,
            bytes: outBytes.length,
            qualityUsed: quality,
            sizeInfo: const SizeInfo(),
          );
        }

        // Single-decode adaptive path with higher min quality and tighter attempts
        final Map<String, dynamic>? fastNear = await _adaptiveSearchInIsolate(
          sourceFile.path,
          safeTargetBytes,
          options.initialQuality,
          nearMinQ,
          options.earlyStopRatio,
          options.maxAttemptsPerDim,
        );
        if (fastNear != null) {
          final Uint8List outBytes = fastNear['bytes'] as Uint8List;
          final int quality = fastNear['quality'] as int;
          final File outFile = await _writeBytesToTemp(outBytes);
          return ImageCompressorResult(
            file: outFile,
            bytes: outBytes.length,
            qualityUsed: quality,
            sizeInfo: const SizeInfo(),
          );
        }
      }

      // Native fast path (Android/iOS): quick binary search on quality only without resizing
      final Map<String, dynamic>? native = await _nativeFastQualitySearch(
        sourceFile.path,
        safeTargetBytes,
        options.initialQuality,
        options.minQuality,
        options.format,
        options.keepExif,
        options.earlyStopRatio,
      );
      if (native != null) {
        final Uint8List outBytes = native['bytes'] as Uint8List;
        final int quality = native['quality'] as int;
        final File outFile = await _writeBytesToTemp(outBytes);
        return ImageCompressorResult(
          file: outFile,
          bytes: outBytes.length,
          qualityUsed: quality,
          sizeInfo: const SizeInfo(),
        );
      }

      // Fast path: run adaptive search entirely inside one isolate with single decode and in-memory trials.
      final Map<String, dynamic>? fast = await _adaptiveSearchInIsolate(
        sourceFile.path,
        safeTargetBytes,
        options.initialQuality,
        options.minQuality,
        options.earlyStopRatio,
        options.maxAttemptsPerDim,
      );
      if (fast != null) {
        final Uint8List outBytes = fast['bytes'] as Uint8List;
        final int quality = fast['quality'] as int;
        final File outFile = await _writeBytesToTemp(outBytes);
        return ImageCompressorResult(
          file: outFile,
          bytes: outBytes.length,
          qualityUsed: quality,
          sizeInfo: const SizeInfo(),
        );
      }

      // Use pure-Dart fallback path (image package) with in-memory trials and write-once at the end.
      // Prefer no-resize first so we can aim for the highest possible quality near the target size.
      final List<int> dimensionCandidates = <int>[
        0,
        3000,
        2048,
        1600,
        1280,
        1024,
        800,
        640,
        480,
        360,
        320,
        256,
        224,
        200,
        180,
        160,
        128,
      ];

      Uint8List? globalBestMem; // <= target
      int? globalBestSize;
      int globalBestQuality = options.initialQuality;

      Uint8List? globalSmallestMem; // overall smallest even if > target
      int? globalSmallestSize;
      int globalSmallestQuality = options.initialQuality;

      final int maxTotalTrials = options.maxTotalTrials;
      int totalTrials = 0;
      bool hitEarlyBand = false;

      for (final int dim in dimensionCandidates) {
        int low = options.minQuality;
        int high = options.initialQuality;
        int attempts = 0;
        while (low <= high && attempts < options.maxAttemptsPerDim) {
          if (totalTrials >= maxTotalTrials) {
            break;
          }
          final int mid = (low + high) >> 1;
          final Uint8List? out = await _encodeWithDartInIsolate(sourceFile.path, mid, dim);
          attempts++;
          totalTrials++;
          if (out == null) break;
          final int size = out.lengthInBytes;

          if (globalSmallestSize == null || size < globalSmallestSize) {
            globalSmallestMem = out;
            globalSmallestSize = size;
            globalSmallestQuality = mid;
          }

          if (size <= safeTargetBytes) {
            if (globalBestSize == null || size > globalBestSize) {
              globalBestMem = out;
              globalBestSize = size;
              globalBestQuality = mid;
            }
            if (_isInEarlyStopBand(size, safeTargetBytes, options.earlyStopRatio)) {
              hitEarlyBand = true;
              break;
            }
            low = mid + 1;
          } else {
            high = mid - 1;
          }
        }

        if (hitEarlyBand) break;
        if (globalBestSize != null && _isInEarlyStopBand(globalBestSize, safeTargetBytes, options.earlyStopRatio)) {
          break;
        }
      }

      // Fallback: if nothing under target was found and we still exceed the target,
      // try again with smaller dimensions and lower min quality bound (down to 10).
      if (globalBestMem == null &&
          globalSmallestSize != null &&
          globalSmallestSize > safeTargetBytes &&
          options.minQuality > 10) {
        final List<int> fallbackDims = <int>[360, 320, 256, 224, 200, 180, 160, 128];
        int fallbackTrials = 0;
        for (final int dim in fallbackDims) {
          int low = 10;
          int high = options.initialQuality;
          int attempts = 0;
          while (low <= high && attempts < options.maxAttemptsPerDim) {
            if (fallbackTrials >= maxTotalTrials) {
              break;
            }
            final int mid = (low + high) >> 1;
            final Uint8List? out = await _encodeWithDartInIsolate(sourceFile.path, mid, dim);
            attempts++;
            fallbackTrials++;
            if (out == null) break;
            final int size = out.lengthInBytes;

            if (globalSmallestSize == null || size < globalSmallestSize) {
              globalSmallestMem = out;
              globalSmallestSize = size;
              globalSmallestQuality = mid;
            }

            if (size <= safeTargetBytes) {
              if (globalBestSize == null || size > globalBestSize) {
                globalBestMem = out;
                globalBestSize = size;
                globalBestQuality = mid;
              }
              if (_isInEarlyStopBand(size, safeTargetBytes, options.earlyStopRatio)) {
                hitEarlyBand = true;
                break;
              }
              low = mid + 1;
            } else {
              high = mid - 1;
            }
          }
          if (hitEarlyBand) break;
        }
      }

      // Decide final output bytes
      Uint8List? chosenMem;
      int chosenLen = originalBytes;
      int chosenQuality = 100;

      if (globalBestMem != null && globalBestSize != null) {
        chosenMem = globalBestMem;
        chosenLen = globalBestSize;
        chosenQuality = globalBestQuality;
      } else if (globalSmallestMem != null && globalSmallestSize != null && globalSmallestSize < originalBytes) {
        chosenMem = globalSmallestMem;
        chosenLen = globalSmallestSize;
        chosenQuality = globalSmallestQuality;
      }

      // Final enforcement: if still above target, force shrink with quality=1 and progressively smaller dims
      if (chosenMem == null && chosenLen > safeTargetBytes) {
        final List<int> enforcementDims = <int>[640, 480, 360, 320, 256, 224, 200, 180, 160, 128, 112, 96, 80];
        for (final int dim in enforcementDims) {
          final Uint8List? out = await _encodeWithDartInIsolate(sourceFile.path, 1, dim);
          if (out == null) continue;
          final int size = out.lengthInBytes;
          if (size <= safeTargetBytes) {
            chosenMem = out;
            chosenLen = size;
            chosenQuality = 1;
            break;
          }
        }
      }

      if (chosenMem == null) {
        // Fallback: original file
        return ImageCompressorResult(
          file: sourceFile,
          bytes: originalBytes,
          qualityUsed: 100,
          sizeInfo: const SizeInfo(),
        );
      }

      final File outFile = await _writeBytesToTemp(chosenMem);
      return ImageCompressorResult(
        file: outFile,
        bytes: chosenMem.lengthInBytes,
        qualityUsed: chosenQuality,
        sizeInfo: const SizeInfo(),
      );
    } finally {
      _sem.release();
    }
  }

  // Keeping native path implementation removed to avoid crashes. If needed in future, re-introduce with guards.

  // (deprecated) _compressWithDart has been replaced by in-memory encoder + final write.

  // In-memory encoder (image package) executed inside an Isolate. No disk I/O here.
  static Future<Uint8List?> _encodeWithDartInIsolate(String sourcePath, int quality, int maxDim) async {
    return Isolate.run<Uint8List?>(() {
      try {
        final Uint8List data = File(sourcePath).readAsBytesSync();
        final img.Image? decoded = img.decodeImage(data);
        if (decoded == null) return null;

        img.Image image = decoded;
        if (maxDim > 0) {
          final int w = image.width;
          final int h = image.height;
          final int maxSide = maxDim;
          final double scale = w > h ? maxSide / w : maxSide / h;
          if (scale < 1.0) {
            final int nw = (w * scale).floor();
            final int nh = (h * scale).floor();
            image = img.copyResize(image, width: nw, height: nh, interpolation: img.Interpolation.linear);
          }
        }

        final List<int> out = img.encodeJpg(image, quality: quality);
        return Uint8List.fromList(out);
      } catch (_) {
        return null;
      }
    });
  }

  // In-memory encode to temp file helper
  static Future<File> _writeBytesToTemp(Uint8List bytes) async {
    final Directory tempDir = await getTemporaryDirectory();
    final String targetPath = '${tempDir.path}/fic_mem_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final File f = File(targetPath);
    await f.writeAsBytes(bytes);
    return f;
  }

  // Native fast path: try platform codec for quick quality-only search (no resize).
  // Returns bytes and quality if a <= target result is found.
  static Future<Map<String, dynamic>?> _nativeFastQualitySearch(
    String sourcePath,
    int targetBytes,
    int initialQuality,
    int minQuality,
    CompressFormat format,
    bool keepExif,
    double earlyStopRatio,
  ) async {
    // Only run on mobile platforms with flutter_image_compress backing
    try {
      int low = minQuality;
      int high = initialQuality;
      int attempts = 0;
      const int maxAttempts = 6; // small cap
      Uint8List? best;
      int? bestSize;
      int bestQuality = initialQuality;

      while (low <= high && attempts < maxAttempts) {
        final int mid = (low + high) >> 1;
        final Uint8List? bytes = await FlutterImageCompress.compressWithFile(
          sourcePath,
          quality: mid,
          format: format,
          keepExif: keepExif,
        );
        attempts++;
        if (bytes == null) break;
        final int size = bytes.lengthInBytes;
        if (size <= targetBytes) {
          if (bestSize == null || size > bestSize) {
            best = bytes;
            bestSize = size;
            bestQuality = mid;
          }
          // Early stop when already within early stop band
          if (size >= (targetBytes * earlyStopRatio).floor()) {
            break;
          }
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }

      if (best != null) {
        return <String, dynamic>{'bytes': best, 'quality': bestQuality};
      }
    } catch (_) {
      // ignore and fall back
    }
    return null;
  }

  // Single-decode adaptive search in isolate: returns nearest-under-target jpeg bytes and quality.
  static Future<Map<String, dynamic>?> _adaptiveSearchInIsolate(
    String sourcePath,
    int targetBytes,
    int initialQuality,
    int minQuality,
    double earlyStopRatio,
    int maxAttemptsPerDim,
  ) async {
    return Isolate.run<Map<String, dynamic>?>(() {
      try {
        final Uint8List data = File(sourcePath).readAsBytesSync();
        final img.Image? decoded = img.decodeImage(data);
        if (decoded == null) return null;

        // ---------- Fast two-probe estimation (no resize) ----------
        Uint8List encode(img.Image im, int q) => Uint8List.fromList(img.encodeJpg(im, quality: q));

        // Two probes at quality 85 and 35 to estimate q* ~ f(size)
        final Uint8List probeHi = encode(decoded, 85);
        final int sHi = probeHi.lengthInBytes;
        final Uint8List probeLo = encode(decoded, 35);
        final int sLo = probeLo.lengthInBytes;

        final int dq = 85 - 35; // 50
        final int ds = sHi - sLo;
        if (dq != 0) {
          final double a = ds / dq; // slope ~ bytes per quality
          final double b = sLo - a * 35.0;
          if (a.abs() > 1e-6) {
            int qStar = ((targetBytes - b) / a).round();
            if (qStar > 100) qStar = 100;
            if (qStar < 10) qStar = 10;

            if (qStar >= minQuality) {
              // try qStar, then a tiny adjust up/down within 2 steps
              int bestSizeLocal = 0;
              Uint8List? bestLocal;
              int bestQ = qStar;
              for (final int q in <int>[qStar, qStar + 5, qStar - 5]) {
                if (q < minQuality || q > 100) continue;
                final Uint8List out = encode(decoded, q);
                final int size = out.lengthInBytes;
                if (size <= targetBytes && size > bestSizeLocal) {
                  bestSizeLocal = size;
                  bestLocal = out;
                  bestQ = q;
                }
                // early break if within early stop band (<= target & >= ratio*target)
                if (bestSizeLocal >= (targetBytes * earlyStopRatio).floor()) {
                  break;
                }
              }
              if (bestLocal != null) {
                return <String, dynamic>{'bytes': bestLocal, 'quality': bestQ};
              }
            }
          }
        }

        // ---------- Predict need to downscale if required quality would be too low ----------
        // If even at q=35 size >> target, predict a scale to target with q around 75
        if (sLo > targetBytes && minQuality > 10) {
          // approximate size at q=75 using linear model; fallback to mid of probes if degenerate
          final double a2 = (sHi - sLo) / dq;
          final double b2 = sLo - a2 * 35.0;
          int s75 = (a2.abs() > 1e-6 ? (a2 * 75.0 + b2).round() : ((sHi + sLo) >> 1));
          if (s75 <= 0) s75 = sLo; // guard
          // scale factor for bytes ~ pixels; so pixels scale ~ bytes scale; dimension scale ~ sqrt(bytes scale)
          final double byteScale = targetBytes / s75;
          double dimScale = byteScale > 0 ? _sqrt(byteScale) : 1.0;
          if (dimScale < 0.1) dimScale = 0.1; // avoid over-shrink

          final int w0 = decoded.width;
          final int h0 = decoded.height;
          final int maxSide0 = w0 > h0 ? w0 : h0;
          final int newMaxSide = (maxSide0 * dimScale).floor();
          if (newMaxSide > 0 && newMaxSide < maxSide0) {
            img.Image image2 = decoded;
            final double scale = w0 > h0 ? newMaxSide / w0 : newMaxSide / h0;
            final int nw = (w0 * scale).floor();
            final int nh = (h0 * scale).floor();
            image2 = img.copyResize(image2, width: nw, height: nh, interpolation: img.Interpolation.linear);

            // Re-probe around q=75 and 50 to refine
            final Uint8List pHi2 = encode(image2, 80);
            final int sHi2 = pHi2.lengthInBytes;
            final Uint8List pLo2 = encode(image2, 50);
            final int sLo2 = pLo2.lengthInBytes;
            final int dq2 = 30;
            final int ds2 = sHi2 - sLo2;
            if (dq2 != 0) {
              final double a3 = ds2 / dq2;
              final double b3 = sLo2 - a3 * 50.0;
              if (a3.abs() > 1e-6) {
                int qStar2 = ((targetBytes - b3) / a3).round();
                if (qStar2 > 100) qStar2 = 100;
                if (qStar2 < 10) qStar2 = 10;
                int bestSize2 = 0;
                Uint8List? best2;
                int bestQ2 = qStar2;
                for (final int q in <int>[qStar2, qStar2 + 5, qStar2 - 5]) {
                  if (q < 10 || q > 100) continue;
                  final Uint8List out = encode(image2, q);
                  final int size = out.lengthInBytes;
                  if (size <= targetBytes && size > bestSize2) {
                    bestSize2 = size;
                    best2 = out;
                    bestQ2 = q;
                  }
                  if (bestSize2 >= (targetBytes * earlyStopRatio).floor()) {
                    break;
                  }
                }
                if (best2 != null) {
                  return <String, dynamic>{'bytes': best2, 'quality': bestQ2};
                }
              }
            }
          }
        }

        final List<int> dims = <int>[0, 2048, 1600, 1280, 1024, 800, 640, 480, 360, 320, 256];
        Uint8List? bestBytes; // <= target
        int? bestSize;
        int bestQuality = initialQuality;

        Uint8List? smallestBytes; // overall smallest
        int? smallestSize;

        for (final int dim in dims) {
          img.Image image = decoded;
          if (dim > 0) {
            final int w = image.width;
            final int h = image.height;
            final int maxSide = dim;
            final double scale = w > h ? maxSide / w : maxSide / h;
            if (scale < 1.0) {
              final int nw = (w * scale).floor();
              final int nh = (h * scale).floor();
              image = img.copyResize(image, width: nw, height: nh, interpolation: img.Interpolation.linear);
            }
          }

          int low = minQuality;
          int high = initialQuality;
          int attempts = 0;
          while (low <= high && attempts < maxAttemptsPerDim) {
            final int mid = (low + high) >> 1;
            final Uint8List out = Uint8List.fromList(img.encodeJpg(image, quality: mid));
            final int size = out.lengthInBytes;
            attempts++;

            if (smallestSize == null || size < smallestSize) {
              smallestBytes = out;
              smallestSize = size;
            }

            if (size <= targetBytes) {
              if (bestSize == null || size > bestSize) {
                bestBytes = out;
                bestSize = size;
                bestQuality = mid;
              }
              if (size >= (targetBytes * earlyStopRatio).floor()) {
                break;
              }
              low = mid + 1;
            } else {
              high = mid - 1;
            }
          }

          // early exit when already within early stop band
          if (bestSize != null && bestSize >= (targetBytes * earlyStopRatio).floor()) {
            break;
          }
        }

        if (bestBytes != null) {
          return <String, dynamic>{'bytes': bestBytes, 'quality': bestQuality};
        }

        // fallback lower bound try with quality down to 10
        if (smallestBytes != null && smallestSize != null && smallestSize > targetBytes && minQuality > 10) {
          final List<int> dims2 = <int>[360, 320, 256, 224, 200, 180, 160, 128];
          for (final int dim in dims2) {
            img.Image image = decoded;
            if (dim > 0) {
              final int w = image.width;
              final int h = image.height;
              final int maxSide = dim;
              final double scale = w > h ? maxSide / w : maxSide / h;
              if (scale < 1.0) {
                final int nw = (w * scale).floor();
                final int nh = (h * scale).floor();
                image = img.copyResize(image, width: nw, height: nh, interpolation: img.Interpolation.linear);
              }
            }
            int low = 10;
            int high = initialQuality;
            for (int i = 0; i < maxAttemptsPerDim && low <= high; i++) {
              final int mid = (low + high) >> 1;
              final Uint8List out = Uint8List.fromList(img.encodeJpg(image, quality: mid));
              final int size = out.lengthInBytes;
              if (size <= targetBytes) {
                return <String, dynamic>{'bytes': out, 'quality': mid};
              }
              high = mid - 1;
            }
          }
        }

        // final enforcement: quality=1 sweep
        final List<int> dims3 = <int>[640, 480, 360, 320, 256, 224, 200, 180, 160, 128, 112, 96, 80];
        for (final int dim in dims3) {
          img.Image image = decoded;
          if (dim > 0) {
            final int w = image.width;
            final int h = image.height;
            final int maxSide = dim;
            final double scale = w > h ? maxSide / w : maxSide / h;
            if (scale < 1.0) {
              final int nw = (w * scale).floor();
              final int nh = (h * scale).floor();
              image = img.copyResize(image, width: nw, height: nh, interpolation: img.Interpolation.linear);
            }
          }
          final Uint8List out = Uint8List.fromList(img.encodeJpg(image, quality: 1));
          if (out.lengthInBytes <= targetBytes) {
            return <String, dynamic>{'bytes': out, 'quality': 1};
          }
        }

        return null;
      } catch (_) {
        return null;
      }
    });
  }

  // lightweight sqrt wrapper for double
  static double _sqrt(double x) {
    double r = x;
    if (x <= 0) return 0;
    // Newton-Raphson 3 iterations (enough for our scaling purpose)
    double g = x;
    for (int i = 0; i < 3; i++) {
      g = 0.5 * (g + x / g);
    }
    r = g;
    return r;
  }

  static Future<File> _copyToTemp(File file) async {
    final Directory tempDir = await getTemporaryDirectory();
    final String filename = 'orig_${DateTime.now().microsecondsSinceEpoch}_${file.uri.pathSegments.last}';
    final File dest = File('${tempDir.path}/$filename');
    return file.copy(dest.path);
  }

  // Helper kept if needed in future; currently unused.
  // static Future<Uint8List> readBytes(File file) async {
  //   return await file.readAsBytes();
  // }
}
