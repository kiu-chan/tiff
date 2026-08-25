import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

import 'support/tiff_fixture_builder.dart';

void main() {
  group('Classic TIFF', () {
    test('decodes an uncompressed 8-bit grayscale image', () {
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [4])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [2])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [4])
        ..setPixelData(Uint8List.fromList([10, 20, 30, 40]));

      final doc = TiffDecoder.decode(builder.build());

      expect(doc.isBigTiff, isFalse);
      expect(doc.byteOrder, TiffByteOrder.little);
      expect(doc.images, hasLength(1));

      final image = doc.images.single;
      expect(image.metadata.width, 2);
      expect(image.metadata.height, 2);
      expect(image.metadata.samplesPerPixel, 1);
      expect(image.metadata.photometric, TiffPhotometric.blackIsZero);

      final raster = image.decode();
      expect(raster.width, 2);
      expect(raster.height, 2);
      expect(raster.samples, [10, 20, 30, 40]);
      expect(raster.sampleAt(1, 1, 0), 40);
    });

    test(
      'decodes an uncompressed 8-bit RGB image (BitsPerSample overflows inline field)',
      () {
        final builder = TiffFixtureBuilder()
          ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
          ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
          ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8, 8, 8])
          ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
          ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
          ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [12])
          ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
          ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [2])
          ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [12])
          ..setPixelData(
            Uint8List.fromList([
              255, 0, 0, // red
              0, 255, 0, // green
              0, 0, 255, // blue
              255, 255, 0, // yellow
            ]),
          );

        final image = TiffDecoder.decode(builder.build()).images.single;
        expect(image.metadata.bitsPerSample, [8, 8, 8]);
        expect(image.metadata.photometric, TiffPhotometric.rgb);

        final raster = image.decode();
        expect(raster.samplesPerPixel, 3);
        expect(
          [
            raster.sampleAt(0, 0, 0),
            raster.sampleAt(0, 0, 1),
            raster.sampleAt(0, 0, 2),
          ],
          [255, 0, 0],
        );
        expect(
          [
            raster.sampleAt(1, 1, 0),
            raster.sampleAt(1, 1, 1),
            raster.sampleAt(1, 1, 2),
          ],
          [255, 255, 0],
        );
      },
    );

    test('decodes multiple strips and reassembles rows in order', () {
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [4, 4])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [2])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [4, 4])
        ..setPixelData(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));

      final raster = TiffDecoder.decode(builder.build()).images.single.decode();
      expect(raster.samples, [1, 2, 3, 4, 5, 6, 7, 8]);
    });

    test('unpacks 1-bit-per-sample rows (bilevel image)', () {
      // 8x1 bilevel row packed MSB-first into a single byte: 1,0,1,1,0,0,1,0
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [1])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [1])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [1])
        ..setPixelData(Uint8List.fromList([0xB2])); // 1011 0010

      final raster = TiffDecoder.decode(builder.build()).images.single.decode();
      expect(raster.samples, [1, 0, 1, 1, 0, 0, 1, 0]);
    });

    test('throws a clear error for unsupported compression', () {
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [
          6,
        ]) // old-style JPEG, not supported
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [1])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [1])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [1])
        ..setPixelData(Uint8List.fromList([0]));

      final image = TiffDecoder.decode(builder.build()).images.single;
      expect(() => image.decode(), throwsA(isA<TiffException>()));
    });

    test('rejects a file with an invalid byte order marker', () {
      expect(
        () => TiffDecoder.decode(Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0])),
        throwsA(isA<TiffException>()),
      );
    });
  });

  group('BigTIFF', () {
    test('decodes an uncompressed 8-bit RGB image (big-endian)', () {
      final builder = TiffFixtureBuilder(bigTiff: true, endian: Endian.big)
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8, 8, 8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [12])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [2])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [12])
        ..setPixelData(
          Uint8List.fromList([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]),
        );

      final doc = TiffDecoder.decode(builder.build());
      expect(doc.isBigTiff, isTrue);
      expect(doc.byteOrder, TiffByteOrder.big);

      final raster = doc.images.single.decode();
      expect(raster.samples, [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]);
    });
  });
}
