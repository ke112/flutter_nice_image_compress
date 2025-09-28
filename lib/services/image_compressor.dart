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
  final int targetSizeInKB;
  final int initialQuality;
  final int minQuality;
  final int step;
  final int? maxWidth;
  final int? maxHeight;
  final CompressFormat format;

  /// EXIF 信息：默认情况下，压缩后的图片不会保留原始图片的 EXIF 信息（如拍摄参数、GPS 位置等）。
  /// 如果需要保留，可以将 keepExif 参数设为 true，但请注意此选项仅对 JPG 格式有效，且不会保留方向信息
  final bool keepExif;

  const ImageCompressorOptions({
    required this.targetSizeInKB,
    this.initialQuality = 92,
    this.minQuality = 40,
    this.step = 4,
    this.maxWidth,
    this.maxHeight,
    this.format = CompressFormat.jpeg,
    this.keepExif = false,
  }) : assert(targetSizeInKB > 0),
       assert(initialQuality <= 100 && initialQuality > 0),
       assert(minQuality > 0 && minQuality <= initialQuality),
       assert(step > 0);
}

class ImageCompressorService {
  /// Compress image to target size in KB with iterative quality reduction and optional downscale.
  static Future<ImageCompressorResult> compressToTarget(
    File sourceFile, {
    required ImageCompressorOptions options,
  }) async {
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

    // Native fast path (Android/iOS): quick binary search on quality only without resizing
    final Map<String, dynamic>? native = await _nativeFastQualitySearch(
      sourceFile.path,
      safeTargetBytes,
      options.initialQuality,
      options.minQuality,
      options.format,
      options.keepExif,
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

    // Use pure-Dart fallback path (image package) with resize candidates.
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

    File? globalBestFile; // <= target
    int? globalBestBytes;
    int globalBestQuality = options.initialQuality;

    File? globalSmallestFile; // overall smallest even if > target
    int? globalSmallestBytes;
    int globalSmallestQuality = options.initialQuality;

    final List<File> garbageTrials = <File>[]; // temporary files to clean up
    const int maxTotalTrials = 60; // allow more trials to reach stricter targets reliably
    int totalTrials = 0;

    for (final int dim in dimensionCandidates) {
      int low = options.minQuality;
      int high = options.initialQuality;

      File? localBestFile; // best candidate under target at this dim (closest to target)
      int? localBestBytes;
      int localBestQuality = options.initialQuality;

      while (low <= high) {
        if (totalTrials >= maxTotalTrials) {
          break;
        }
        final int mid = (low + high) >> 1;
        File? trial;
        try {
          trial = await _compressWithDart(sourcePath: sourceFile.path, quality: mid, maxDim: dim);
        } catch (_) {
          trial = null;
        }

        if (trial == null) {
          break;
        }

        final int trialBytes = await trial.length();
        totalTrials++;

        // Track global smallest (also ensure we don't keep more than needed)
        if (globalSmallestBytes == null || trialBytes < globalSmallestBytes) {
          // Old smallest (if not same file) becomes deletable
          if (globalSmallestFile != null && globalSmallestFile.path != trial.path) {
            garbageTrials.add(globalSmallestFile);
          }
          globalSmallestFile = trial;
          globalSmallestBytes = trialBytes;
          globalSmallestQuality = mid;
        } else {
          // Not keeping this trial, mark for deletion later
          garbageTrials.add(trial);
        }

        if (trialBytes <= safeTargetBytes) {
          // Update local best to the largest bytes under target (closest to target)
          if (localBestBytes == null || trialBytes > localBestBytes) {
            if (localBestFile != null && localBestFile.path != trial.path) {
              garbageTrials.add(localBestFile);
            }
            localBestFile = trial;
            localBestBytes = trialBytes;
            localBestQuality = mid;
          } else {
            // Not keeping this trial, mark for deletion later
            garbageTrials.add(trial);
          }
          // Try higher quality while staying under target
          low = mid + 1;
        } else {
          // Too large, reduce quality
          high = mid - 1;
        }
      }

      // Promote local best (closest under target in this dim) to global best
      if (localBestFile != null && localBestBytes != null) {
        if (globalBestBytes == null || localBestBytes > globalBestBytes) {
          if (globalBestFile != null && globalBestFile.path != localBestFile.path) {
            garbageTrials.add(globalBestFile);
          }
          globalBestFile = localBestFile;
          globalBestBytes = localBestBytes;
          globalBestQuality = localBestQuality;
        } else if (localBestFile.path != globalBestFile!.path) {
          // Not keeping this local best
          garbageTrials.add(localBestFile);
        }
      }

      // Early exit: once we reach a good result under target, stop trying smaller dims
      if (globalBestBytes != null && globalBestBytes <= safeTargetBytes) {
        break;
      }
    }

    // Fallback: if nothing under target was found and we still exceed the target,
    // try again with smaller dimensions and lower min quality bound (down to 10).
    if (globalBestBytes == null &&
        globalSmallestBytes != null &&
        globalSmallestBytes > safeTargetBytes &&
        options.minQuality > 10) {
      final List<int> fallbackDims = <int>[360, 320, 256, 224, 200, 180, 160, 128];
      int fallbackTrials = 0;
      const int maxFallbackTrials = 40;
      for (final int dim in fallbackDims) {
        int low = 10;
        int high = options.initialQuality;
        while (low <= high) {
          if (fallbackTrials >= maxFallbackTrials) {
            break;
          }
          final int mid = (low + high) >> 1;
          File? trial;
          try {
            trial = await _compressWithDart(sourcePath: sourceFile.path, quality: mid, maxDim: dim);
          } catch (_) {
            trial = null;
          }
          if (trial == null) {
            break;
          }
          final int trialBytes = await trial.length();
          fallbackTrials++;

          // Track global smallest as well
          if (globalSmallestBytes == null || trialBytes < globalSmallestBytes) {
            if (globalSmallestFile != null && globalSmallestFile.path != trial.path) {
              garbageTrials.add(globalSmallestFile);
            }
            globalSmallestFile = trial;
            globalSmallestBytes = trialBytes;
            globalSmallestQuality = mid;
          } else {
            garbageTrials.add(trial);
          }

          if (trialBytes <= safeTargetBytes) {
            if (globalBestBytes == null || trialBytes > globalBestBytes) {
              if (globalBestFile != null && globalBestFile.path != trial.path) {
                garbageTrials.add(globalBestFile);
              }
              globalBestFile = trial;
              globalBestBytes = trialBytes;
              globalBestQuality = mid;
            }
            // try raising quality while staying under target
            low = mid + 1;
          } else {
            high = mid - 1;
          }
        }

        if (globalBestBytes != null && globalBestBytes <= safeTargetBytes) {
          break;
        }
      }
    }

    // Decide final output
    File chosenFile;
    int chosenBytes;
    int chosenQuality;

    if (globalBestFile != null && globalBestBytes != null) {
      chosenFile = globalBestFile;
      chosenBytes = globalBestBytes;
      chosenQuality = globalBestQuality;
    } else if (globalSmallestFile != null && globalSmallestBytes != null && globalSmallestBytes < originalBytes) {
      chosenFile = globalSmallestFile;
      chosenBytes = globalSmallestBytes;
      chosenQuality = globalSmallestQuality;
    } else {
      // Fallback: original
      chosenFile = sourceFile;
      chosenBytes = originalBytes;
      chosenQuality = 100;
    }

    // Final enforcement: if still above target, force shrink with quality=1 and progressively smaller dims
    if (chosenBytes > safeTargetBytes) {
      final List<int> enforcementDims = <int>[640, 480, 360, 320, 256, 224, 200, 180, 160, 128, 112, 96, 80];
      for (final int dim in enforcementDims) {
        File? trial;
        try {
          trial = await _compressWithDart(sourcePath: sourceFile.path, quality: 1, maxDim: dim);
        } catch (_) {
          trial = null;
        }
        if (trial == null) continue;
        final int trialBytes = await trial.length();
        if (trialBytes <= safeTargetBytes) {
          garbageTrials.add(chosenFile);
          chosenFile = trial;
          chosenBytes = trialBytes;
          chosenQuality = 1;
          break;
        } else {
          garbageTrials.add(trial);
        }
      }
    }

    // Cleanup unused temp files
    for (final File f in garbageTrials) {
      if (f.path != chosenFile.path) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }

    return ImageCompressorResult(
      file: chosenFile,
      bytes: chosenBytes,
      qualityUsed: chosenQuality,
      sizeInfo: const SizeInfo(),
    );
  }

  // Keeping native path implementation removed to avoid crashes. If needed in future, re-introduce with guards.

  // Pure Dart JPEG compressor using image package in an Isolate
  static Future<File?> _compressWithDart({
    required String sourcePath,
    required int quality,
    required int maxDim,
  }) async {
    final Uint8List? bytes = await Isolate.run<Uint8List?>(() {
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

    if (bytes == null) return null;
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String targetPath = '${tempDir.path}/fic_dart_${DateTime.now().microsecondsSinceEpoch}.jpg';
      final File f = File(targetPath);
      await f.writeAsBytes(bytes);
      return f;
    } catch (_) {
      return null;
    }
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
                // early break if close enough (<= target & >= 90% target)
                if (bestSizeLocal >= (targetBytes * 0.90).floor()) {
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
                  if (bestSize2 >= (targetBytes * 0.90).floor()) {
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
          const int maxAttemptsPerDim = 8;
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
              low = mid + 1;
            } else {
              high = mid - 1;
            }
          }

          // early exit when already close enough (within 5%)
          if (bestSize != null && bestSize >= (targetBytes * 0.90).floor()) {
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
            for (int i = 0; i < 6 && low <= high; i++) {
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
