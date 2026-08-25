import 'dart:math' as math;
import 'dart:typed_data';

import '../core/tag_type.dart';
import '../layout/chunk_encoder.dart';
import '../tags/tag_id.dart';
import '../tiff_exception.dart';
import 'ifd_field.dart';
import 'tiff_image_spec.dart';

/// Builds strip-organized pixel data (and the tags describing it) for
/// writing a non-tiled [TiffImageSpec].
class StripWriter {
  const StripWriter._();

  static List<Uint8List> buildChunks(TiffImageSpec spec, Endian endian) {
    final rowsPerStrip = spec.rowsPerStrip ?? spec.height;
    if (rowsPerStrip <= 0) {
      throw const TiffException('rowsPerStrip must be positive');
    }

    final chunks = <Uint8List>[];
    var rowIndex = 0;
    while (rowIndex < spec.height) {
      final rows = math.min(rowsPerStrip, spec.height - rowIndex);
      final start = rowIndex * spec.width * spec.samplesPerPixel;
      final end = (rowIndex + rows) * spec.width * spec.samplesPerPixel;
      chunks.add(
        ChunkEncoder.encodeChunk(
          samples: spec.samples.sublist(start, end),
          compression: spec.compression,
          predictor: spec.predictor,
          rows: rows,
          columns: spec.width,
          samplesPerPixel: spec.samplesPerPixel,
          bitsPerSample: spec.bitsPerSample,
          endian: endian,
        ),
      );
      rowIndex += rows;
    }
    return chunks;
  }

  static List<IfdField> buildFields({
    required TiffImageSpec spec,
    required List<Uint8List> chunks,
    required TiffTagType offsetType,
  }) {
    final rowsPerStrip = spec.rowsPerStrip ?? spec.height;
    return [
      IfdField(TiffTagId.rowsPerStrip, TiffTagType.tLong, [rowsPerStrip]),
      // Values are a zero placeholder here; TiffWriter patches in the real
      // offsets once pixel-data placement is known (see its top-level doc).
      IfdField(
        TiffTagId.stripOffsets,
        offsetType,
        List.filled(chunks.length, 0),
      ),
      IfdField(TiffTagId.stripByteCounts, offsetType, [
        for (final c in chunks) c.length,
      ]),
    ];
  }
}
