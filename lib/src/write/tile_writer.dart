import 'dart:math' as math;
import 'dart:typed_data';

import '../core/tag_type.dart';
import '../layout/chunk_encoder.dart';
import '../tags/tag_id.dart';
import '../tiff_exception.dart';
import 'ifd_field.dart';
import 'tiff_image_spec.dart';

/// Builds tile-organized pixel data (and the tags describing it) for
/// writing a tiled [TiffImageSpec].
///
/// Edge tiles are padded with zero samples up to the full tile size before
/// encoding — TIFF always stores complete tiles, even at image edges; a
/// decoder (this package's included) crops the padding back off on read.
class TileWriter {
  const TileWriter._();

  static List<Uint8List> buildChunks(TiffImageSpec spec, Endian endian) {
    final tileWidth = spec.tileWidth!;
    final tileLength = spec.tileLength!;
    if (tileWidth <= 0 || tileLength <= 0) {
      throw const TiffException('tileWidth and tileLength must be positive');
    }

    final tilesAcross = (spec.width + tileWidth - 1) ~/ tileWidth;
    final tilesDown = (spec.height + tileLength - 1) ~/ tileLength;
    final chunks = <Uint8List>[];

    for (var ty = 0; ty < tilesDown; ty++) {
      for (var tx = 0; tx < tilesAcross; tx++) {
        final originX = tx * tileWidth;
        final originY = ty * tileLength;
        final validWidth = math.min(tileWidth, spec.width - originX);
        final validHeight = math.min(tileLength, spec.height - originY);

        final tileSamples = List<int>.filled(
          tileWidth * tileLength * spec.samplesPerPixel,
          0,
        );
        final rowLen = validWidth * spec.samplesPerPixel;
        for (var row = 0; row < validHeight; row++) {
          final srcStart =
              ((originY + row) * spec.width + originX) * spec.samplesPerPixel;
          final destStart = row * tileWidth * spec.samplesPerPixel;
          for (var i = 0; i < rowLen; i++) {
            tileSamples[destStart + i] = spec.samples[srcStart + i];
          }
        }

        chunks.add(
          ChunkEncoder.encodeChunk(
            samples: tileSamples,
            compression: spec.compression,
            predictor: spec.predictor,
            rows: tileLength,
            columns: tileWidth,
            samplesPerPixel: spec.samplesPerPixel,
            bitsPerSample: spec.bitsPerSample,
            endian: endian,
          ),
        );
      }
    }
    return chunks;
  }

  static List<IfdField> buildFields({
    required TiffImageSpec spec,
    required List<Uint8List> chunks,
    required TiffTagType offsetType,
  }) {
    return [
      IfdField(TiffTagId.tileWidth, TiffTagType.tLong, [spec.tileWidth!]),
      IfdField(TiffTagId.tileLength, TiffTagType.tLong, [spec.tileLength!]),
      // Values are a zero placeholder here; TiffWriter patches in the real
      // offsets once pixel-data placement is known (see its top-level doc).
      IfdField(
        TiffTagId.tileOffsets,
        offsetType,
        List.filled(chunks.length, 0),
      ),
      IfdField(TiffTagId.tileByteCounts, offsetType, [
        for (final c in chunks) c.length,
      ]),
    ];
  }
}
