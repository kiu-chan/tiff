import 'dart:math' as math;

import '../core/byte_reader.dart';
import '../image/image_metadata.dart';
import '../raster/raster_buffer.dart';
import '../region/tiff_region.dart';
import '../tiff_exception.dart';
import 'chunk_decoder.dart';
import 'layout_common.dart';

/// Decodes tile-organized pixel data into a [TiffRasterBuffer].
///
/// Edge tiles (when width/height aren't multiples of the tile size) are
/// decoded at full tile size — TIFF pads them — and then cropped when
/// copied into the output buffer.
class TileLayout {
  const TileLayout._();

  static TiffRasterBuffer decode({
    required TiffByteReader reader,
    required TiffImageMetadata metadata,
  }) => decodeRegion(
    reader: reader,
    metadata: metadata,
    region: TiffRegion.fullImage(metadata),
  );

  /// Decodes only [region], skipping every tile that doesn't overlap it —
  /// entirely, including the disk/network read behind [reader.readBytes] —
  /// so a small crop of a huge image only touches the tiles it actually
  /// needs (tiles beat strips here: both axes can be skipped, not just rows).
  static TiffRasterBuffer decodeRegion({
    required TiffByteReader reader,
    required TiffImageMetadata metadata,
    required TiffRegion region,
  }) {
    region.validateWithin(metadata);
    final bitsPerSample = LayoutCommon.uniformBitsPerSample(metadata);

    final samplesPerPixel = metadata.samplesPerPixel;
    final width = metadata.width;
    final height = metadata.height;
    final tileWidth = metadata.tileWidth!;
    final tileLength = metadata.tileLength!;
    final tileOffsets = metadata.tileOffsets!;
    final tileByteCounts = metadata.tileByteCounts!;

    final tilesAcross = (width + tileWidth - 1) ~/ tileWidth;
    final tilesDown = (height + tileLength - 1) ~/ tileLength;
    if (tileOffsets.length != tilesAcross * tilesDown) {
      throw TiffException(
        'Expected ${tilesAcross * tilesDown} tiles (${tilesAcross}x$tilesDown), found ${tileOffsets.length}',
      );
    }

    final regionRowLength = region.width * samplesPerPixel;
    final samples = List<int>.filled(
      region.width * region.height * samplesPerPixel,
      0,
    );

    final tileMinX = region.x ~/ tileWidth;
    final tileMaxX = (region.x + region.width - 1) ~/ tileWidth;
    final tileMinY = region.y ~/ tileLength;
    final tileMaxY = (region.y + region.height - 1) ~/ tileLength;

    for (var ty = tileMinY; ty <= tileMaxY; ty++) {
      for (var tx = tileMinX; tx <= tileMaxX; tx++) {
        final tileIndex = ty * tilesAcross + tx;
        final compressedBytes = reader.readBytes(
          tileOffsets[tileIndex],
          tileByteCounts[tileIndex],
        );

        final isJpeg = metadata.compression == 6 || metadata.compression == 7;
        // See StripLayout's identical check for why this is checked upfront
        // rather than reactively: most JPEG-in-TIFF encoders write each
        // tile as a self-contained JPEG, but some instead split one
        // continuous JPEG scan across chunk boundaries — a self-contained
        // tile that fails to decode for some *other* reason should surface
        // that error directly instead of being wrongly merged with
        // unrelated tiles.
        if (isJpeg && !ChunkDecoder.isSelfContainedJpeg(compressedBytes)) {
          return _decodeViaStitchedJpeg(
            reader: reader,
            metadata: metadata,
            region: region,
            bitsPerSample: bitsPerSample,
          );
        }

        final tileSamples = ChunkDecoder.decodeChunk(
          compressedBytes: compressedBytes,
          compression: metadata.compression,
          predictor: metadata.predictor,
          rows: tileLength,
          columns: tileWidth,
          samplesPerPixel: samplesPerPixel,
          bitsPerSample: bitsPerSample,
          endian: reader.endian,
          t4Options: metadata.t4Options,
          t6Options: metadata.t6Options,
          jpegTables: metadata.jpegTables,
        );

        final originX = tx * tileWidth;
        final originY = ty * tileLength;
        final tileValidWidth = math.min(tileWidth, width - originX);
        final tileValidHeight = math.min(tileLength, height - originY);

        final overlapX0 = math.max(originX, region.x);
        final overlapX1 = math.min(
          originX + tileValidWidth,
          region.x + region.width,
        );
        final overlapY0 = math.max(originY, region.y);
        final overlapY1 = math.min(
          originY + tileValidHeight,
          region.y + region.height,
        );
        if (overlapX1 <= overlapX0 || overlapY1 <= overlapY0) continue;

        final overlapLen = (overlapX1 - overlapX0) * samplesPerPixel;
        for (var row = overlapY0; row < overlapY1; row++) {
          final srcStart =
              ((row - originY) * tileWidth + (overlapX0 - originX)) *
              samplesPerPixel;
          final destStart =
              (row - region.y) * regionRowLength +
              (overlapX0 - region.x) * samplesPerPixel;
          for (var i = 0; i < overlapLen; i++) {
            samples[destStart + i] = tileSamples[srcStart + i];
          }
        }
      }
    }

    return TiffRasterBuffer(
      width: region.width,
      height: region.height,
      samplesPerPixel: samplesPerPixel,
      bitsPerSample: bitsPerSample,
      samples: samples,
    );
  }

  /// Fallback for a JPEG-compressed page where at least one tile failed to
  /// decode on its own — see [ChunkDecoder.decodeStitchedJpegChunks] and
  /// [StripLayout]'s identical fallback. A genuine tiled JPEG scan can't be
  /// stitched by concatenation (each tile is its own independent 2D block,
  /// not a fragment of one raster-order scan the way strips can be) — this
  /// only helps for the same pathological case strips have: an encoder that
  /// wrote one whole-page JPEG scan, arbitrarily chopped into
  /// tile-sized-looking byte ranges. So this reassembles every tile (in
  /// storage order) and decodes it against the *page's* full dimensions,
  /// not a single tile's, then crops out [region] — there's no way to
  /// decode only part of one continuous JPEG scan, so a region request
  /// against a page shaped like this costs as much as [decode] would.
  static TiffRasterBuffer _decodeViaStitchedJpeg({
    required TiffByteReader reader,
    required TiffImageMetadata metadata,
    required TiffRegion region,
    required int bitsPerSample,
  }) {
    final samplesPerPixel = metadata.samplesPerPixel;
    final width = metadata.width;
    final height = metadata.height;
    final tileOffsets = metadata.tileOffsets!;
    final tileByteCounts = metadata.tileByteCounts!;

    final chunks = [
      for (var i = 0; i < tileOffsets.length; i++)
        reader.readBytes(tileOffsets[i], tileByteCounts[i]),
    ];
    final fullSamples = ChunkDecoder.decodeStitchedJpegChunks(
      chunks: chunks,
      rows: height,
      columns: width,
      samplesPerPixel: samplesPerPixel,
      jpegTables: metadata.jpegTables,
    );

    final regionRowLength = region.width * samplesPerPixel;
    final samples = List<int>.filled(
      region.width * region.height * samplesPerPixel,
      0,
    );
    for (var r = 0; r < region.height; r++) {
      final absRow = region.y + r;
      final srcStart = (absRow * width + region.x) * samplesPerPixel;
      final destStart = r * regionRowLength;
      for (var i = 0; i < regionRowLength; i++) {
        samples[destStart + i] = fullSamples[srcStart + i];
      }
    }

    return TiffRasterBuffer(
      width: region.width,
      height: region.height,
      samplesPerPixel: samplesPerPixel,
      bitsPerSample: bitsPerSample,
      samples: samples,
    );
  }
}
