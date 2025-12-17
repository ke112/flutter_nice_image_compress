import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_effort_image_compress/high_effort_image_compress.dart';

void main() {
  group('ImageCompressorService', () {
    test('CompressFormat enum values', () {
      expect(CompressFormat.jpeg, equals(CompressFormat.jpeg));
      expect(CompressFormat.png, equals(CompressFormat.png));
      expect(CompressFormat.webp, equals(CompressFormat.webp));
    });

    test('ImageCompressorOptions default values', () {
      final options = ImageCompressorOptions(targetSizeInKB: 100);

      expect(options.targetSizeInKB, equals(100));
      expect(options.initialQuality, equals(92));
      expect(options.minQuality, equals(40));
      expect(options.format, equals(CompressFormat.jpeg));
      expect(options.keepExif, isFalse);
      expect(options.earlyStopRatio, equals(0.95));
      expect(options.nearTargetFactor, equals(1.2));
      expect(options.preferredMinQuality, equals(80));
      expect(options.maxAttemptsPerDim, equals(5));
      expect(options.maxTotalTrials, equals(24));
    });

    test('ImageCompressorOptions validation', () {
      expect(() => ImageCompressorOptions(targetSizeInKB: 0), throwsAssertionError);
      expect(() => ImageCompressorOptions(targetSizeInKB: -1), throwsAssertionError);
      expect(() => ImageCompressorOptions(targetSizeInKB: 100, initialQuality: 0), throwsAssertionError);
      expect(() => ImageCompressorOptions(targetSizeInKB: 100, minQuality: -1), throwsAssertionError);
      expect(() => ImageCompressorOptions(targetSizeInKB: 100, minQuality: 50, initialQuality: 40), throwsAssertionError);
    });

    test('ImageCompressorOptions custom values', () {
      final options = ImageCompressorOptions(
        targetSizeInKB: 500,
        initialQuality: 85,
        minQuality: 50,
        maxWidth: 1920,
        maxHeight: 1080,
        format: CompressFormat.png,
        keepExif: true,
        earlyStopRatio: 0.90,
        nearTargetFactor: 1.5,
        preferredMinQuality: 70,
        maxAttemptsPerDim: 8,
        maxTotalTrials: 30,
      );

      expect(options.targetSizeInKB, equals(500));
      expect(options.initialQuality, equals(85));
      expect(options.minQuality, equals(50));
      expect(options.maxWidth, equals(1920));
      expect(options.maxHeight, equals(1080));
      expect(options.format, equals(CompressFormat.png));
      expect(options.keepExif, isTrue);
      expect(options.earlyStopRatio, equals(0.90));
      expect(options.nearTargetFactor, equals(1.5));
      expect(options.preferredMinQuality, equals(70));
      expect(options.maxAttemptsPerDim, equals(8));
      expect(options.maxTotalTrials, equals(30));
    });

    test('SizeInfo creation', () {
      const sizeInfo = SizeInfo(width: 1920, height: 1080);
      expect(sizeInfo.width, equals(1920));
      expect(sizeInfo.height, equals(1080));

      const emptySizeInfo = SizeInfo();
      expect(emptySizeInfo.width, isNull);
      expect(emptySizeInfo.height, isNull);
    });

    test('ImageCompressorResult creation', () {
      // Create a mock file using a temporary file approach
      final tempFile = File('test_file.jpg');
      final result = ImageCompressorResult(
        file: tempFile,
        bytes: 102400,
        qualityUsed: 85,
        sizeInfo: const SizeInfo(width: 800, height: 600),
      );

      expect(result.bytes, equals(102400));
      expect(result.qualityUsed, equals(85));
      expect(result.sizeInfo.width, equals(800));
      expect(result.sizeInfo.height, equals(600));
      expect(result.file, equals(tempFile));
    });
  });

  group('Utility functions', () {
    test('CompressFormat to string', () {
      expect(CompressFormat.jpeg.toString(), contains('CompressFormat.jpeg'));
      expect(CompressFormat.png.toString(), contains('CompressFormat.png'));
      expect(CompressFormat.webp.toString(), contains('CompressFormat.webp'));
    });

    test('SizeInfo equality', () {
      const size1 = SizeInfo(width: 100, height: 200);
      const size2 = SizeInfo(width: 100, height: 200);
      const size3 = SizeInfo(width: 150, height: 200);

      expect(size1, equals(size2));
      expect(size1, isNot(equals(size3)));
    });

    test('ImageCompressorOptions properties', () {
      final options1 = ImageCompressorOptions(targetSizeInKB: 100);
      final options2 = ImageCompressorOptions(targetSizeInKB: 100);
      final options3 = ImageCompressorOptions(targetSizeInKB: 200);

      expect(options1.targetSizeInKB, equals(options2.targetSizeInKB));
      expect(options1.targetSizeInKB, isNot(equals(options3.targetSizeInKB)));
    });
  });

  group('Integration tests', () {
    test('Library exports', () {
      // Test that all expected exports are available
      expect(ImageCompressorService, isNotNull);
      expect(ImageCompressorResult, isNotNull);
      expect(ImageCompressorOptions, isNotNull);
      expect(SizeInfo, isNotNull);
      expect(CompressFormat, isNotNull);
    });
  });
}
