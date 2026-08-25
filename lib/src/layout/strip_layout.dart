import 'dart:math' as math;

import '../core/byte_reader.dart';
import '../image/image_metadata.dart';
import '../raster/raster_buffer.dart';
import '../region/tiff_region.dart';
import '../tiff_exception.dart';
import 'chunk_decoder.dart';
import 'layout_common.dart';

/// Decodes strip-organized pixel data into a [TiffRasterBuffer].
class StripLayout {
  const StripLayout._();

  static TiffRasterBuffer decode({
    required TiffByteReader reader,
    required TiffImageMetadata metadata,
  }) =>
      decodeRegion(reader: reader, metadata: metadata, region: TiffRegion.fullImage(metadata));

  /// Decodes only [region], skipping every strip that doesn't overlap it —
  /// entirely, including the disk/network read behind [reader.readBytes] —
  /// so a small crop of a huge image only touches the strips it actually
  /// needs.
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
    final rowsPerStrip = metadata.rowsPerStrip > 0 ? metadata.rowsPerStrip : height;

    if (metadata.stripOffsets.length != metadata.stripByteCounts.length) {
      throw const TiffException('StripOffsets and StripByteCounts count mismatch');
    }

    final regionRowLength = region.width * samplesPerPixel;
    final samples = List<int>.filled(region.width * region.height * samplesPerPixel, 0);

    var rowIndex = 0;
    for (var stripIndex = 0; stripIndex < metadata.stripOffsets.length; stripIndex++) {
      final stripFirstRow = rowIndex;
      final rowsInThisStrip = math.min(rowsPerStrip, height - rowIndex);
      final stripLastRow = stripFirstRow + rowsInThisStrip;
      rowIndex = stripLastRow;

      if (stripLastRow <= region.y || stripFirstRow >= region.y + region.height) {
        continue;
      }

      final compressedBytes = reader.readBytes(
        metadata.stripOffsets[stripIndex],
        metadata.stripByteCounts[stripIndex],
      );
      final stripSamples = ChunkDecoder.decodeChunk(
        compressedBytes: compressedBytes,
        compression: metadata.compression,
        predictor: metadata.predictor,
        rows: rowsInThisStrip,
        columns: width,
        samplesPerPixel: samplesPerPixel,
        bitsPerSample: bitsPerSample,
        endian: reader.endian,
      );

      for (var r = 0; r < rowsInThisStrip; r++) {
        final absRow = stripFirstRow + r;
        if (absRow < region.y || absRow >= region.y + region.height) continue;
        final srcStart = (r * width + region.x) * samplesPerPixel;
        final destStart = (absRow - region.y) * regionRowLength;
        for (var i = 0; i < regionRowLength; i++) {
          samples[destStart + i] = stripSamples[srcStart + i];
        }
      }
    }

    if (rowIndex != height) {
      throw TiffException('Decoded row count ($rowIndex) does not match ImageLength ($height)');
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
