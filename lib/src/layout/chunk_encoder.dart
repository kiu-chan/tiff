import 'dart:typed_data';

import '../compression/codec_registry.dart';
import '../compression/predictor.dart';
import '../raster/pixel_packer.dart';
import '../tiff_exception.dart';

/// Encodes one chunk's worth of samples (a strip or a tile) into
/// compressed bytes: pack bits -> apply predictor (per row) -> compress.
///
/// The write-side mirror of [ChunkDecoder](chunk_decoder.dart); kept as a
/// separate class (rather than reusing ChunkDecoder) because the two
/// pipelines run in opposite order and share little beyond calling into
/// the same compression/predictor/bit-packing primitives.
class ChunkEncoder {
  const ChunkEncoder._();

  static Uint8List encodeChunk({
    required List<int> samples,
    required int compression,
    required int predictor,
    required int rows,
    required int columns,
    required int samplesPerPixel,
    required int bitsPerSample,
    required Endian endian,
  }) {
    final bytesPerRow = (columns * samplesPerPixel * bitsPerSample + 7) ~/ 8;
    final packed = Uint8List(bytesPerRow * rows);

    for (var r = 0; r < rows; r++) {
      final rowStart = r * columns * samplesPerPixel;
      final rowEnd = rowStart + columns * samplesPerPixel;
      // A zero-copy view when possible (the common case: samples is the
      // Uint8List a `TileWriter`/`StripWriter` row buffer already is) —
      // `sublist` would otherwise allocate and copy this row's worth of
      // samples fresh for every single row of every chunk.
      final rowSamples = samples is Uint8List ? Uint8List.sublistView(samples, rowStart, rowEnd) : samples.sublist(rowStart, rowEnd);
      final rowBytes = PixelPacker.packRow(
        samples: rowSamples,
        bitsPerSample: bitsPerSample,
        endian: endian,
      );

      if (predictor == 2) {
        Predictor.applyHorizontalDifferencing(
          rowBytes: rowBytes,
          bitsPerSample: bitsPerSample,
          samplesPerPixel: samplesPerPixel,
          endian: endian,
        );
      } else if (predictor != 1) {
        throw TiffException('Predictor $predictor is not supported yet');
      }

      packed.setRange(r * bytesPerRow, (r + 1) * bytesPerRow, rowBytes);
    }

    return CompressionCodecRegistry.encode(compression, packed);
  }
}
