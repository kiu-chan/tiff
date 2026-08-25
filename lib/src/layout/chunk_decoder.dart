import 'dart:typed_data';

import '../compression/codec_registry.dart';
import '../compression/predictor.dart';
import '../raster/pixel_unpacker.dart';
import '../tiff_exception.dart';

/// Decodes one compressed chunk (a strip or a tile) into unpacked samples:
/// decompress -> undo predictor (per row) -> unpack bit-packed samples.
///
/// Shared by [StripLayout] and [TileLayout] so compression/predictor
/// handling lives in exactly one place.
class ChunkDecoder {
  const ChunkDecoder._();

  static List<int> decodeChunk({
    required Uint8List compressedBytes,
    required int compression,
    required int predictor,
    required int rows,
    required int columns,
    required int samplesPerPixel,
    required int bitsPerSample,
    required Endian endian,
  }) {
    final decompressed = CompressionCodecRegistry.decode(compression, compressedBytes);
    final bytesPerRow = (columns * samplesPerPixel * bitsPerSample + 7) ~/ 8;
    final expectedLength = bytesPerRow * rows;
    if (decompressed.length < expectedLength) {
      throw TiffException(
          'Decompressed chunk is smaller than expected: got ${decompressed.length} bytes, need $expectedLength');
    }

    final samples = List<int>.filled(columns * rows * samplesPerPixel, 0);
    for (var r = 0; r < rows; r++) {
      final rowStart = r * bytesPerRow;
      final rowBytes = Uint8List.sublistView(decompressed, rowStart, rowStart + bytesPerRow);

      if (predictor == 2) {
        Predictor.undoHorizontalDifferencing(
          rowBytes: rowBytes,
          bitsPerSample: bitsPerSample,
          samplesPerPixel: samplesPerPixel,
          endian: endian,
        );
      } else if (predictor != 1) {
        throw TiffException('Predictor $predictor is not supported yet');
      }

      final rowSamples = PixelUnpacker.unpackRow(
        rowBytes: rowBytes,
        bitsPerSample: bitsPerSample,
        sampleCount: columns * samplesPerPixel,
        endian: endian,
      );
      final destStart = r * columns * samplesPerPixel;
      for (var i = 0; i < rowSamples.length; i++) {
        samples[destStart + i] = rowSamples[i];
      }
    }
    return samples;
  }
}
