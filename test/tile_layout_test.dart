import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

import 'support/tiff_fixture_builder.dart';

void main() {
  group('Tile layout', () {
    test('decodes a 4x4 image made of four 2x2 tiles', () {
      // Image, row-major: 1  2  3  4
      //                    5  6  7  8
      //                    9 10 11 12
      //                   13 14 15 16
      // Tiles (2x2 each), row-major within each tile:
      final tile00 = [1, 2, 5, 6];
      final tile01 = [3, 4, 7, 8];
      final tile10 = [9, 10, 13, 14];
      final tile11 = [11, 12, 15, 16];
      final pixelData = Uint8List.fromList([...tile00, ...tile01, ...tile10, ...tile11]);

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.tileWidth, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.tileLength, TiffTagType.tShort, [2])
        ..addTileOffsetsTag(TiffTagId.tileOffsets, TiffTagType.tLong, [4, 4, 4, 4])
        ..addTag(TiffTagId.tileByteCounts, TiffTagType.tLong, [4, 4, 4, 4])
        ..setPixelData(pixelData);

      final image = TiffDecoder.decode(builder.build()).images.single;
      expect(image.metadata.isTiled, isTrue);

      final raster = image.decode();
      expect(raster.samples, [
        1, 2, 3, 4, //
        5, 6, 7, 8, //
        9, 10, 11, 12, //
        13, 14, 15, 16, //
      ]);
    });

    test('crops edge tiles when image size is not a multiple of the tile size', () {
      // 3x3 image with 2x2 tiles -> 2x2 grid of tiles, right/bottom tiles
      // are only half-used and must be cropped on assembly.
      // Image, row-major: 1 2 3
      //                    4 5 6
      //                    7 8 9
      final tile00 = [1, 2, 4, 5]; // full
      final tile01 = [3, 0, 6, 0]; // right column real, padding on the right
      final tile10 = [7, 8, 0, 0]; // bottom row real, padding below
      final tile11 = [9, 0, 0, 0]; // only top-left cell real
      final pixelData = Uint8List.fromList([...tile00, ...tile01, ...tile10, ...tile11]);

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.tileWidth, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.tileLength, TiffTagType.tShort, [2])
        ..addTileOffsetsTag(TiffTagId.tileOffsets, TiffTagType.tLong, [4, 4, 4, 4])
        ..addTag(TiffTagId.tileByteCounts, TiffTagType.tLong, [4, 4, 4, 4])
        ..setPixelData(pixelData);

      final raster = TiffDecoder.decode(builder.build()).images.single.decode();
      expect(raster.samples, [
        1, 2, 3, //
        4, 5, 6, //
        7, 8, 9, //
      ]);
    });
  });
}
