import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

import 'support/recording_byte_source.dart';
import 'support/tiff_fixture_builder.dart';

void main() {
  group('Region decode', () {
    test(
      'strip layout only reads strips that intersect the requested region',
      () {
        final pixelData = Uint8List.fromList([
          1, 2, 3, 4, //
          5, 6, 7, 8, //
          9, 10, 11, 12, //
          13, 14, 15, 16, //
        ]);
        final builder = TiffFixtureBuilder()
          ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [4])
          ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [4])
          ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
          ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
          ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
          ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
            4,
            4,
            4,
            4,
          ])
          ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
          ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [1])
          ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [4, 4, 4, 4])
          ..setPixelData(pixelData);

        final recording = RecordingByteSource(
          MemoryByteSource(builder.build()),
        );
        final image = TiffDecoder.decodeSource(recording).images.single;
        final stripOffsets = image.metadata.stripOffsets;
        recording.readOffsets.clear();

        final raster = image.decodeRegion(
          const TiffRegion(x: 1, y: 1, width: 2, height: 2),
        );
        expect(raster.width, 2);
        expect(raster.height, 2);
        expect(raster.samples, [6, 7, 10, 11]);

        expect(
          recording.readOffsets,
          containsAll([stripOffsets[1], stripOffsets[2]]),
        );
        expect(recording.readOffsets, isNot(contains(stripOffsets[0])));
        expect(recording.readOffsets, isNot(contains(stripOffsets[3])));
      },
    );

    test(
      'tile layout only reads tiles that intersect the requested region',
      () {
        final tile00 = [1, 2, 5, 6];
        final tile01 = [3, 4, 7, 8];
        final tile10 = [9, 10, 13, 14];
        final tile11 = [11, 12, 15, 16];
        final pixelData = Uint8List.fromList([
          ...tile00,
          ...tile01,
          ...tile10,
          ...tile11,
        ]);

        final builder = TiffFixtureBuilder()
          ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [4])
          ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [4])
          ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
          ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
          ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
          ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
          ..addTag(TiffTagId.tileWidth, TiffTagType.tShort, [2])
          ..addTag(TiffTagId.tileLength, TiffTagType.tShort, [2])
          ..addTileOffsetsTag(TiffTagId.tileOffsets, TiffTagType.tLong, [
            4,
            4,
            4,
            4,
          ])
          ..addTag(TiffTagId.tileByteCounts, TiffTagType.tLong, [4, 4, 4, 4])
          ..setPixelData(pixelData);

        final recording = RecordingByteSource(
          MemoryByteSource(builder.build()),
        );
        final image = TiffDecoder.decodeSource(recording).images.single;
        final tileOffsets = image.metadata.tileOffsets!;
        recording.readOffsets.clear();

        // Bottom-right 2x2 tile only (tile index 3).
        final raster = image.decodeRegion(
          const TiffRegion(x: 2, y: 2, width: 2, height: 2),
        );
        expect(raster.samples, [11, 12, 15, 16]);

        expect(recording.readOffsets, [tileOffsets[3]]);
      },
    );

    test('decodeRegionRgba8 matches a manual crop of decodeRgba8', () {
      final pixelData = Uint8List.fromList([
        1, 2, 3, 4, //
        5, 6, 7, 8, //
        9, 10, 11, 12, //
        13, 14, 15, 16, //
      ]);
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          4,
          4,
          4,
          4,
        ])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [1])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [4, 4, 4, 4])
        ..setPixelData(pixelData);

      final image = TiffDecoder.decode(builder.build()).images.single;
      final fullRgba = image.decodeRgba8();
      final regionRgba = image.decodeRegionRgba8(
        const TiffRegion(x: 1, y: 1, width: 2, height: 2),
      );

      Uint8List cropPixel(int x, int y) {
        final o = (y * 4 + x) * 4;
        return fullRgba.sublist(o, o + 4);
      }

      expect(regionRgba.sublist(0, 4), cropPixel(1, 1));
      expect(regionRgba.sublist(4, 8), cropPixel(2, 1));
      expect(regionRgba.sublist(8, 12), cropPixel(1, 2));
      expect(regionRgba.sublist(12, 16), cropPixel(2, 2));
    });

    test('rejects an out-of-bounds region with a clear error', () {
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
        ..setPixelData(Uint8List.fromList([1, 2, 3, 4]));

      final image = TiffDecoder.decode(builder.build()).images.single;
      expect(
        () => image.decodeRegion(
          const TiffRegion(x: 1, y: 1, width: 5, height: 5),
        ),
        throwsA(isA<TiffException>()),
      );
    });
  });
}
