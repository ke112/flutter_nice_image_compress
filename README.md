# nice_image_compress

[![pub package](https://img.shields.io/pub/v/nice_image_compress.svg)](https://pub.dev/packages/nice_image_compress)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

A powerful Flutter plugin for advanced image compression with intelligent algorithms that balance size and quality.

一个强大的 Flutter 图片压缩插件，采用智能算法在大小和质量之间取得平衡。

## Features

- ✅ **Intelligent Compression** - Advanced algorithms that balance file size and image quality
- ✅ **Target Size Control** - Compress images to specific target file sizes in KB
- ✅ **Multiple Formats** - Support for JPEG, PNG, and WebP formats
- ✅ **Adaptive Quality** - Automatic quality adjustment to meet size requirements
- ✅ **Dimension Control** - Optional maximum width/height constraints
- ✅ **Batch Processing** - Efficient concurrent processing with semaphore control
- ✅ **Isolate Execution** - Off-main-thread processing for smooth UI performance
- ✅ **Pure Dart** - No native dependencies, works on all Flutter platforms

## Problem Solved

Traditional image compression often results in either poor quality at small file sizes or unnecessarily large files at high quality. This plugin uses intelligent algorithms to find the optimal balance, including:

- Adaptive quality search with binary search optimization
- Multi-dimensional scaling attempts (no resize, then progressive downscaling)
- Early stop mechanisms when target size is achieved
- Fallback strategies for edge cases
- Concurrent processing limits to prevent resource exhaustion

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  nice_image_compress: ^1.0.0
```

Then run:

```bash
flutter pub get
```

## Usage

### Basic Usage

```dart
import 'package:nice_image_compress/nice_image_compress.dart';
import 'dart:io';

class ImageCompressor {
  Future<void> compressImage() async {
    final File imageFile = File('/path/to/your/image.jpg');

    final result = await ImageCompressorService.compressToTarget(
      imageFile,
      options: ImageCompressorOptions(targetSizeInKB: 500), // 500KB target
    );

    print('Original size: ${imageFile.lengthSync()} bytes');
    print('Compressed size: ${result.bytes} bytes');
    print('Quality used: ${result.qualityUsed}%');

    // Use result.file for the compressed image
    final compressedFile = result.file;
  }
}
```

### Advanced Configuration

```dart
final options = ImageCompressorOptions(
  targetSizeInKB: 300,           // Target size in KB
  initialQuality: 92,            // Starting quality (0-100)
  minQuality: 40,                // Minimum quality (0-100)
  maxWidth: 1920,                // Maximum width (optional)
  maxHeight: 1080,               // Maximum height (optional)
  format: CompressFormat.jpeg,   // Output format
  earlyStopRatio: 0.95,          // Early stop when within 95% of target
  nearTargetFactor: 1.2,         // Near-target optimization threshold
  maxAttemptsPerDim: 5,          // Max attempts per dimension
  maxTotalTrials: 24,            // Max total compression attempts
);

final result = await ImageCompressorService.compressToTarget(
  imageFile,
  options: options,
);
```

### Different Output Formats

```dart
// JPEG compression (default)
final jpegOptions = ImageCompressorOptions(
  targetSizeInKB: 500,
  format: CompressFormat.jpeg,
);

// PNG compression (lossless, may not achieve small sizes)
final pngOptions = ImageCompressorOptions(
  targetSizeInKB: 1000,
  format: CompressFormat.png,
);

// WebP compression (falls back to JPEG in current implementation)
final webpOptions = ImageCompressorOptions(
  targetSizeInKB: 400,
  format: CompressFormat.webp,
);
```

## API Reference

### ImageCompressorService

Static service class providing image compression functionality.

#### Methods

**compressToTarget(File sourceFile, {required ImageCompressorOptions options}) → Future\<ImageCompressorResult\>**

Compresses an image file to meet the target size requirements using intelligent algorithms.

- `sourceFile`: The source image file to compress
- `options`: Compression configuration options

Returns a `Future<ImageCompressorResult>` containing the compressed image data.

### ImageCompressorOptions

Configuration class for compression parameters.

| Property              | Type             | Default               | Description                                      |
| --------------------- | ---------------- | --------------------- | ------------------------------------------------ |
| `targetSizeInKB`      | `int`            | required              | Target file size in KB                           |
| `initialQuality`      | `int`            | `92`                  | Starting compression quality (0-100)             |
| `minQuality`          | `int`            | `40`                  | Minimum allowed quality (0-100)                  |
| `maxWidth`            | `int?`           | `null`                | Maximum image width (optional)                   |
| `maxHeight`           | `int?`           | `null`                | Maximum image height (optional)                  |
| `format`              | `CompressFormat` | `CompressFormat.jpeg` | Output image format                              |
| `keepExif`            | `bool`           | `false`               | Preserve EXIF data (JPEG only)                   |
| `earlyStopRatio`      | `double`         | `0.95`                | Stop when within ratio of target size            |
| `nearTargetFactor`    | `double`         | `1.2`                 | Near-target optimization threshold               |
| `preferredMinQuality` | `int`            | `80`                  | Preferred minimum quality for near-target images |
| `maxAttemptsPerDim`   | `int`            | `5`                   | Max attempts per dimension                       |
| `maxTotalTrials`      | `int`            | `24`                  | Max total compression attempts                   |

### ImageCompressorResult

Result class containing compression outcome.

| Property      | Type       | Description                       |
| ------------- | ---------- | --------------------------------- |
| `file`        | `File`     | The compressed image file         |
| `bytes`       | `int`      | Size of compressed image in bytes |
| `qualityUsed` | `int`      | Quality setting used (0-100)      |
| `sizeInfo`    | `SizeInfo` | Image dimension information       |

### CompressFormat

Enum for supported compression formats.

- `CompressFormat.jpeg` - JPEG format (recommended)
- `CompressFormat.png` - PNG format (lossless)
- `CompressFormat.webp` - WebP format (falls back to JPEG)

### SizeInfo

Class containing image dimension information.

| Property | Type   | Description            |
| -------- | ------ | ---------------------- |
| `width`  | `int?` | Image width in pixels  |
| `height` | `int?` | Image height in pixels |

## Algorithm Details

The compression algorithm uses a multi-stage approach:

1. **Fast Path**: For images near target size, uses higher quality thresholds
2. **Adaptive Search**: Binary search on quality with early stopping
3. **Multi-dimensional**: Tries different resolutions if quality alone isn't sufficient
4. **Fallback Strategies**: Progressive dimension reduction for difficult cases
5. **Final Enforcement**: Quality=1 with smallest dimensions as last resort

## Performance Considerations

- Uses Dart isolates for off-main-thread processing
- Implements semaphore-based concurrency control (max 3 concurrent operations)
- Early stopping prevents unnecessary computation
- Memory-efficient in-memory compression trials

## Example

See the [example](example/) directory for a complete sample application.

```bash
cd example
flutter run
```

## Limitations

- WebP encoding currently falls back to JPEG (image package limitation)
- EXIF preservation is not yet implemented
- Size information in results is currently placeholder

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Getting Started

This project is a starting point for a Flutter
[plug-in package](https://flutter.dev/to/develop-plugins),
a specialized package that includes platform-specific implementation code for
Android and/or iOS.

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

The plugin project was generated without specifying the `--platforms` flag, no platforms are currently supported.
To add platforms, run `flutter create -t plugin --platforms <platforms> .` in this directory.
You can also find a detailed instruction on how to add platforms in the `pubspec.yaml` at https://flutter.dev/to/pubspec-plugin-platforms.

<img src="example/assets/images/demo_1.png" width="300" />

<img src="example/assets/images/demo_2.png" width="300" />
