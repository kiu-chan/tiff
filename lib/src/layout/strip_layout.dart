import 'dart:math' as math;
import 'dart:typed_data';

import '../core/byte_reader.dart';
import '../image/image_metadata.dart';
import '../image/planar_configuration.dart';
import '../raster/pixel_unpacker.dart';
import '../raster/raster_buffer.dart';
import '../tiff_exception.dart';

/// Decodes strip-organized, uncompressed pixel data (Compression == 1) into
/// a [TiffRasterBuffer].
class StripLayout {
  const StripLayout._();

  static TiffRasterBuffer decodeUncompressed({
    required TiffByteReader reader,
    required TiffImageMetadata metadata,
  }) {
    if (metadata.planarConfiguration == TiffPlanarConfiguration.planar) {
      throw const TiffException(
          'Planar configuration is not supported yet (Phase 1 supports chunky/interleaved data only)');
    }

    final bitsSet = metadata.bitsPerSample.toSet();
    if (bitsSet.length > 1) {
      throw const TiffException('Differing BitsPerSample per channel is not supported yet');
    }
    final bitsPerSample = metadata.bitsPerSample.isNotEmpty ? metadata.bitsPerSample.first : 1;

    final samplesPerPixel = metadata.samplesPerPixel;
    final width = metadata.width;
    final height = metadata.height;
    final rowsPerStrip = metadata.rowsPerStrip > 0 ? metadata.rowsPerStrip : height;
    final bytesPerRow = (width * samplesPerPixel * bitsPerSample + 7) ~/ 8;

    if (metadata.stripOffsets.length != metadata.stripByteCounts.length) {
      throw const TiffException('StripOffsets and StripByteCounts count mismatch');
    }

    final samples = List<int>.filled(width * height * samplesPerPixel, 0);

    var rowIndex = 0;
    for (var stripIndex = 0; stripIndex < metadata.stripOffsets.length; stripIndex++) {
      final stripBytes = reader.readBytes(
        metadata.stripOffsets[stripIndex],
        metadata.stripByteCounts[stripIndex],
      );
      final rowsInThisStrip = math.min(rowsPerStrip, height - rowIndex);

      for (var r = 0; r < rowsInThisStrip; r++) {
        final rowByteOffset = r * bytesPerRow;
        if (rowByteOffset + bytesPerRow > stripBytes.length) {
          throw TiffException('Strip $stripIndex is smaller than expected at row $r');
        }
        final rowBytes = Uint8List.sublistView(stripBytes, rowByteOffset, rowByteOffset + bytesPerRow);
        final rowSamples = PixelUnpacker.unpackRow(
          rowBytes: rowBytes,
          bitsPerSample: bitsPerSample,
          sampleCount: width * samplesPerPixel,
          endian: reader.endian,
        );
        final destStart = rowIndex * width * samplesPerPixel;
        for (var i = 0; i < rowSamples.length; i++) {
          samples[destStart + i] = rowSamples[i];
        }
        rowIndex++;
      }
    }

    if (rowIndex != height) {
      throw TiffException('Decoded row count ($rowIndex) does not match ImageLength ($height)');
    }

    return TiffRasterBuffer(
      width: width,
      height: height,
      samplesPerPixel: samplesPerPixel,
      bitsPerSample: bitsPerSample,
      samples: samples,
    );
  }
}
