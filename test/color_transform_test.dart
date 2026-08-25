import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

import 'support/tiff_fixture_builder.dart';

TiffFixtureBuilder _baseBuilder({
  required int width,
  required int height,
  required List<int> bitsPerSample,
  required int samplesPerPixel,
  required int photometric,
  required Uint8List pixelData,
}) {
  return TiffFixtureBuilder()
    ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [width])
    ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [height])
    ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, bitsPerSample)
    ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
    ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [photometric])
    ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [pixelData.length])
    ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [samplesPerPixel])
    ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [height])
    ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [pixelData.length])
    ..setPixelData(pixelData);
}

void main() {
  group('ColorTransform', () {
    test('WhiteIsZero grayscale is inverted', () {
      final builder = _baseBuilder(
        width: 2,
        height: 1,
        bitsPerSample: [8],
        samplesPerPixel: 1,
        photometric: 0, // WhiteIsZero
        pixelData: Uint8List.fromList([0, 255]),
      );
      final rgba = TiffDecoder.decode(builder.build()).images.single.decodeRgba8();
      expect(rgba, [255, 255, 255, 255, 0, 0, 0, 255]);
    });

    test('BlackIsZero grayscale passes through', () {
      final builder = _baseBuilder(
        width: 2,
        height: 1,
        bitsPerSample: [8],
        samplesPerPixel: 1,
        photometric: 1, // BlackIsZero
        pixelData: Uint8List.fromList([0, 255]),
      );
      final rgba = TiffDecoder.decode(builder.build()).images.single.decodeRgba8();
      expect(rgba, [0, 0, 0, 255, 255, 255, 255, 255]);
    });

    test('RGBA (4 samples/pixel) carries the alpha channel through', () {
      final builder = _baseBuilder(
        width: 1,
        height: 1,
        bitsPerSample: [8, 8, 8, 8],
        samplesPerPixel: 4,
        photometric: 2, // RGB
        pixelData: Uint8List.fromList([10, 20, 30, 128]),
      );
      final rgba = TiffDecoder.decode(builder.build()).images.single.decodeRgba8();
      expect(rgba, [10, 20, 30, 128]);
    });

    test('Palette uses the ColorMap tag to resolve indices to colors', () {
      final builder = _baseBuilder(
        width: 2,
        height: 1,
        bitsPerSample: [1],
        samplesPerPixel: 1,
        photometric: 3, // Palette
        pixelData: Uint8List.fromList([0x80]), // bits: 1,0 (MSB-first) -> index1, index0
      )..addTag(TiffTagId.colorMap, TiffTagType.tShort, [
          0, 65535, // red table: index0=0, index1=65535
          65535, 0, // green table: index0=65535, index1=0
          0, 0, // blue table
        ]);
      final rgba = TiffDecoder.decode(builder.build()).images.single.decodeRgba8();
      // pixel0 = index1 -> red channel 65535>>8=255, green 0 -> (255,0,0)
      // pixel1 = index0 -> red 0, green 65535>>8=255 -> (0,255,0)
      expect(rgba, [255, 0, 0, 255, 0, 255, 0, 255]);
    });

    test('CMYK converts pure cyan correctly', () {
      final builder = _baseBuilder(
        width: 1,
        height: 1,
        bitsPerSample: [8, 8, 8, 8],
        samplesPerPixel: 4,
        photometric: 5, // CMYK
        pixelData: Uint8List.fromList([255, 0, 0, 0]), // full cyan, no black
      );
      final rgba = TiffDecoder.decode(builder.build()).images.single.decodeRgba8();
      expect(rgba, [0, 255, 255, 255]);
    });

    test('non-subsampled YCbCr with zero chroma decodes to gray', () {
      final builder = _baseBuilder(
        width: 1,
        height: 1,
        bitsPerSample: [8, 8, 8],
        samplesPerPixel: 3,
        photometric: 6, // YCbCr
        pixelData: Uint8List.fromList([128, 128, 128]),
      )..addTag(TiffTagId.yCbCrSubSampling, TiffTagType.tShort, [1, 1]);
      final rgba = TiffDecoder.decode(builder.build()).images.single.decodeRgba8();
      expect(rgba, [128, 128, 128, 255]);
    });

    test('subsampled YCbCr is rejected with a clear error', () {
      final builder = _baseBuilder(
        width: 1,
        height: 1,
        bitsPerSample: [8, 8, 8],
        samplesPerPixel: 3,
        photometric: 6, // YCbCr
        pixelData: Uint8List.fromList([128, 128, 128]),
      )..addTag(TiffTagId.yCbCrSubSampling, TiffTagType.tShort, [2, 2]);
      final image = TiffDecoder.decode(builder.build()).images.single;
      expect(() => image.decodeRgba8(), throwsA(isA<TiffException>()));
    });
  });
}
