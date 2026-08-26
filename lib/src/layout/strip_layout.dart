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
  }) => decodeRegion(
    reader: reader,
    metadata: metadata,
    region: TiffRegion.fullImage(metadata),
  );

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
    final rowsPerStrip = metadata.rowsPerStrip > 0
        ? metadata.rowsPerStrip
        : height;

    if (metadata.stripOffsets.length != metadata.stripByteCounts.length) {
      throw const TiffException(
        'StripOffsets and StripByteCounts count mismatch',
      );
    }

    final regionRowLength = region.width * samplesPerPixel;
    final samples = List<int>.filled(
      region.width * region.height * samplesPerPixel,
      0,
    );

    var rowIndex = 0;
    for (
      var stripIndex = 0;
      stripIndex < metadata.stripOffsets.length;
      stripIndex++
    ) {
      final stripFirstRow = rowIndex;
      final rowsInThisStrip = math.min(rowsPerStrip, height - rowIndex);
      final stripLastRow = stripFirstRow + rowsInThisStrip;
      rowIndex = stripLastRow;

      if (stripLastRow <= region.y ||
          stripFirstRow >= region.y + region.height) {
        continue;
      }

      // A strip with a byte count of 0 is a "sparse" strip: some encoders
      // (whole-slide-image scanners in particular) never write strips that
      // would be empty/background, and rely on the reader leaving that
      // region at its default fill value instead. There's no data to decode
      // here at all — skip straight to the next strip.
      if (metadata.stripByteCounts[stripIndex] == 0) continue;

      final compressedBytes = reader.readBytes(
        metadata.stripOffsets[stripIndex],
        metadata.stripByteCounts[stripIndex],
      );

      final isJpeg = metadata.compression == 6 || metadata.compression == 7;
      // Most JPEG-in-TIFF encoders write each strip as a self-contained
      // JPEG (TIFF Technical Note 2) — but some instead split one
      // continuous JPEG scan across strip boundaries with no per-strip
      // frame header, which only decodes reassembled with every other
      // strip of the page. Checked upfront (not reactively, by catching
      // whatever a failed decode throws) so a self-contained strip that
      // fails to decode for some *other* reason surfaces that error
      // directly instead of being wrongly merged with unrelated strips.
      if (isJpeg && !ChunkDecoder.isSelfContainedJpeg(compressedBytes)) {
        return _decodeViaStitchedJpeg(
          reader: reader,
          metadata: metadata,
          region: region,
          bitsPerSample: bitsPerSample,
        );
      }

      final stripSamples = ChunkDecoder.decodeChunk(
        compressedBytes: compressedBytes,
        compression: metadata.compression,
        predictor: metadata.predictor,
        rows: rowsInThisStrip,
        columns: width,
        samplesPerPixel: samplesPerPixel,
        bitsPerSample: bitsPerSample,
        endian: reader.endian,
        t4Options: metadata.t4Options,
        t6Options: metadata.t6Options,
        jpegTables: metadata.jpegTables,
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
      throw TiffException(
        'Decoded row count ($rowIndex) does not match ImageLength ($height)',
      );
    }

    return TiffRasterBuffer(
      width: region.width,
      height: region.height,
      samplesPerPixel: samplesPerPixel,
      bitsPerSample: bitsPerSample,
      samples: samples,
    );
  }

  /// Fallback for a JPEG-compressed page where at least one strip failed to
  /// decode on its own — see [ChunkDecoder.decodeStitchedJpegChunks].
  /// Reassembles every strip into one continuous JPEG stream, decodes it
  /// once, then crops out [region]. Unlike the strip-by-strip path above,
  /// this always reads and decodes the *whole* page — there's no way to
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

    final chunks = [
      for (var i = 0; i < metadata.stripOffsets.length; i++)
        reader.readBytes(metadata.stripOffsets[i], metadata.stripByteCounts[i]),
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
