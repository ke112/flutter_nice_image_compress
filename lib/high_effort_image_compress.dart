/// A powerful Flutter plugin for advanced image compression with intelligent algorithms
/// that balance size and quality.
///
/// This plugin provides sophisticated image compression capabilities that can:
/// - Compress images to target file sizes with high quality preservation
/// - Support various image formats and dimensions
/// - Handle batch processing efficiently
/// - Provide detailed compression results and statistics
///
/// ## Example
///
/// ```dart
/// import 'package:high_effort_image_compress/high_effort_image_compress.dart';
///
/// // Basic usage
/// final result = await ImageCompressorService.compressToTarget(
///   File('/path/to/image.jpg'),
///   options: ImageCompressorOptions(targetSizeInKB: 500),
/// );
///
/// print('Compressed to ${result.bytes} bytes with quality ${result.qualityUsed}');
/// ```

export 'src/image_compressor.dart'
    show ImageCompressorService, ImageCompressorResult, ImageCompressorOptions, SizeInfo, CompressFormat;
