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

  static List<Uint8List> buildChunks(
    TiffImageSpec spec,
    Endian endian, {
    void Function(int chunkIndex, int chunkCount)? onChunkEncoded,
  }) {
    final tileWidth = spec.tileWidth!;
    final tileLength = spec.tileLength!;
    if (tileWidth <= 0 || tileLength <= 0) {
      throw const TiffException('tileWidth and tileLength must be positive');
    }

    final tilesAcross = (spec.width + tileWidth - 1) ~/ tileWidth;
    final tilesDown = (spec.height + tileLength - 1) ~/ tileLength;
    final chunkCount = tilesAcross * tilesDown;
    final chunks = <Uint8List>[];

    for (var ty = 0; ty < tilesDown; ty++) {
      for (var tx = 0; tx < tilesAcross; tx++) {
        final originX = tx * tileWidth;
        final originY = ty * tileLength;
        final validWidth = math.min(tileWidth, spec.width - originX);
        final validHeight = math.min(tileLength, spec.height - originY);

        // A typed buffer sized to `bitsPerSample` rather than a generic
        // `List<int>.filled` — the latter stores each sample as a full
        // 8-byte tagged slot (vs. 1 byte here for the common 8-bit-RGB
        // case this feeds from `TiffDisplayOptimizer`), and `setRange`
        // below only gets its bulk-memmove fast path when both sides are
        // typed data of the same element size.
        final tileSamples = _newSampleBuffer(
          spec.bitsPerSample,
          tileWidth * tileLength * spec.samplesPerPixel,
        );
        final rowLen = validWidth * spec.samplesPerPixel;
        for (var row = 0; row < validHeight; row++) {
          final srcStart =
              ((originY + row) * spec.width + originX) * spec.samplesPerPixel;
          final destStart = row * tileWidth * spec.samplesPerPixel;
          tileSamples.setRange(
            destStart,
            destStart + rowLen,
            spec.samples,
            srcStart,
          );
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
        onChunkEncoded?.call(chunks.length, chunkCount);
      }
    }
    return chunks;
  }

  /// The smallest typed-data list that can hold every value an
  /// [bitsPerSample]-wide sample can take, used instead of a generic
  /// `List<int>` for [buildChunks]' per-tile scratch buffer — see its call
  /// site for why that matters. Anything above 16 bits (24- or 32-bit
  /// samples) falls back to [Uint32List]; there's no `Uint24List`, and a
  /// 24-bit sample's values fit comfortably in one anyway.
  static List<int> _newSampleBuffer(int bitsPerSample, int length) {
    if (bitsPerSample <= 8) return Uint8List(length);
    if (bitsPerSample <= 16) return Uint16List(length);
    return Uint32List(length);
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
