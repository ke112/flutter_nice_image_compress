// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_effort_image_compress/high_effort_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Image compression integration test', (WidgetTester tester) async {
    // Create a test image
    final image = img.Image(width: 256, height: 256);
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final r = (x * 255) ~/ image.width;
        final g = (y * 255) ~/ image.height;
        final b = 128;
        image.setPixelRgb(x, y, r, g, b);
      }
    }

    final originalBytes = img.encodeJpg(image, quality: 95);
    final tempDir = await getTemporaryDirectory();
    final testFile = File('${tempDir.path}/integration_test.jpg');
    await testFile.writeAsBytes(originalBytes);

    // Test compression
    final options = ImageCompressorOptions(targetSizeInKB: 10, initialQuality: 80, minQuality: 30);

    final result = await ImageCompressorService.compressToTarget(testFile, options: options);

    // Verify results
    expect(result, isA<ImageCompressorResult>());
    expect(result.bytes, greaterThan(0));
    expect(result.bytes, lessThan(originalBytes.length));
    expect(result.qualityUsed, greaterThanOrEqualTo(30));
    expect(result.qualityUsed, lessThanOrEqualTo(80));
    expect(await result.file.exists(), isTrue);
  });
}
