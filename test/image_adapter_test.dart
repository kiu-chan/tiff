import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_image_adapter.dart';
import 'package:tiff/src/compression/jpeg_hook.dart';

import 'support/tiff_fixture_builder.dart';

void main() {
  group('TiffImageAdapter conversions', () {
    test('toImage() matches decodeRgba8()', () {
      final samples = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120];
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          samples.length,
        ])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [samples.length])
        ..setPixelData(Uint8List.fromList(samples));

      final page = TiffDecoder.decode(builder.build()).images.single;
      final expectedRgba = page.decodeRgba8();

      final image = TiffImageAdapter.toImage(page);
      expect(image.width, 2);
      expect(image.height, 2);
      expect(image.getBytes(order: img.ChannelOrder.rgba), expectedRgba);
    });

    test('toTiffImageSpec() round-trips an RGB image through the encoder', () {
      final image = img.Image(width: 3, height: 2, numChannels: 3);
      var value = 0;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          image.setPixelRgb(x, y, value, value + 1, value + 2);
          value += 3;
        }
      }

      final spec = TiffImageAdapter.toTiffImageSpec(image);
      final bytes = TiffEncoder.encode([spec]);
      final decoded = TiffDecoder.decode(bytes).images.single;
      expect(
        decoded.decode().samples,
        image.getBytes(order: img.ChannelOrder.rgb),
      );
    });

    test('toTiffImageSpec() keeps alpha when asked and the source has it', () {
      final image = img.Image(width: 2, height: 1, numChannels: 4);
      image.setPixelRgba(0, 0, 1, 2, 3, 255);
      image.setPixelRgba(1, 0, 4, 5, 6, 128);

      final spec = TiffImageAdapter.toTiffImageSpec(image, keepAlpha: true);
      expect(spec.samplesPerPixel, 4);
      final bytes = TiffEncoder.encode([spec]);
      final decoded = TiffDecoder.decode(bytes).images.single;
      expect(
        decoded.decode().samples,
        image.getBytes(order: img.ChannelOrder.rgba),
      );
    });
  });

  group('JPEG-in-TIFF (Compression 7) via the adapter', () {
    test('decodes a strip whose JPEG data has no shared JPEGTables', () {
      TiffImageAdapter.enableJpegSupport();

      final source = img.Image(width: 4, height: 4, numChannels: 3);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          source.setPixelRgb(x, y, x * 60, y * 60, 128);
        }
      }
      final jpegBytes = Uint8List.fromList(img.encodeJpg(source, quality: 95));

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          jpegBytes.length,
        ])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [
          jpegBytes.length,
        ])
        ..setPixelData(jpegBytes);

      final page = TiffDecoder.decode(builder.build()).images.single;
      final decoded = page.decode();

      // JPEG is lossy, so compare against re-decoding our own encoded bytes
      // rather than the original source samples.
      final reference = img
          .decodeJpg(jpegBytes)!
          .getBytes(order: img.ChannelOrder.rgb);
      expect(decoded.samples, reference);
    });

    test(
      'decodeRgba8() does not re-apply YCbCr when PhotometricInterpretation says so',
      () {
        // Real-world JPEG-in-TIFF files almost always declare
        // PhotometricInterpretation=YCbCr (6) even though a JPEG decoder
        // already converts to RGB internally — decodeRgba8() must not treat
        // those already-RGB samples as YCbCr and convert them a second time.
        TiffImageAdapter.enableJpegSupport();

        final source = img.Image(width: 2, height: 2, numChannels: 3);
        source.setPixelRgb(0, 0, 200, 30, 30);
        source.setPixelRgb(1, 0, 30, 200, 30);
        source.setPixelRgb(0, 1, 30, 30, 200);
        source.setPixelRgb(1, 1, 128, 128, 128);
        final jpegBytes = Uint8List.fromList(
          img.encodeJpg(source, quality: 100),
        );

        final builder = TiffFixtureBuilder()
          ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
          ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
          ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
          ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
          ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
          ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [
            6,
          ]) // YCbCr
          ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
            jpegBytes.length,
          ])
          ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [
            jpegBytes.length,
          ])
          ..setPixelData(jpegBytes);

        final page = TiffDecoder.decode(builder.build()).images.single;
        expect(page.metadata.photometric, TiffPhotometric.ycbcr);

        final rgba = page.decodeRgba8();
        final referenceRgb = img
            .decodeJpg(jpegBytes)!
            .getBytes(order: img.ChannelOrder.rgb);
        final expectedRgba = Uint8List(referenceRgb.length ~/ 3 * 4);
        for (var p = 0; p < referenceRgb.length ~/ 3; p++) {
          expectedRgba[p * 4] = referenceRgb[p * 3];
          expectedRgba[p * 4 + 1] = referenceRgb[p * 3 + 1];
          expectedRgba[p * 4 + 2] = referenceRgb[p * 3 + 2];
          expectedRgba[p * 4 + 3] = 255;
        }
        expect(rgba, expectedRgba);
      },
    );

    test('throws a clear error when no JPEG decoder has been registered', () {
      JpegCodecHook.decoder = null;
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [4])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [4])
        ..setPixelData(Uint8List.fromList([0, 0, 0, 0]));

      final page = TiffDecoder.decode(builder.build()).images.single;
      expect(() => page.decode(), throwsA(isA<TiffException>()));

      // Leave the hook registered again for any tests that run after this one.
      TiffImageAdapter.enableJpegSupport();
    });
  });
}
