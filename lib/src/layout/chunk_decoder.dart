import 'dart:typed_data';

import '../compression/codec_registry.dart';
import '../compression/jpeg_hook.dart';
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
    int t4Options = 0,
    int t6Options = 0,
    Uint8List? jpegTables,
  }) {
    final isCcitt = compression == 2 || compression == 3 || compression == 4;
    if (isCcitt && (bitsPerSample != 1 || samplesPerPixel != 1)) {
      throw const TiffException('CCITT compression requires 1 bit per sample and 1 sample per pixel');
    }

    if (compression == 6 || compression == 7) {
      return _decodeJpegChunk(
        compressedBytes: compressedBytes,
        rows: rows,
        columns: columns,
        samplesPerPixel: samplesPerPixel,
        jpegTables: jpegTables,
      );
    }

    final decompressed = CompressionCodecRegistry.decode(
      compression,
      compressedBytes,
      columns: columns,
      rows: rows,
      t4Options: t4Options,
      t6Options: t6Options,
    );
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

  /// JPEG-compressed chunks (Compression 6/7) bypass the
  /// decompress/predictor/unpack pipeline entirely — the JPEG stream already
  /// *is* the final decoded, interleaved 8-bit samples, produced by whatever
  /// decoder is registered via [JpegCodecHook] (see
  /// `package:tiff/tiff_image_adapter.dart`).
  static List<int> _decodeJpegChunk({
    required Uint8List compressedBytes,
    required int rows,
    required int columns,
    required int samplesPerPixel,
    required Uint8List? jpegTables,
  }) {
    final decoder = JpegCodecHook.decoder;
    if (decoder == null) {
      throw const TiffException(
          'JPEG-compressed TIFF data needs a JPEG decoder — import package:tiff/tiff_image_adapter.dart '
          'and call TiffImageAdapter.enableJpegSupport() once before decoding');
    }

    final jpegBytes =
        (jpegTables != null && jpegTables.isNotEmpty) ? _mergeJpegTables(jpegTables, compressedBytes) : compressedBytes;

    return decoder(jpegBytes, columns: columns, rows: rows, samplesPerPixel: samplesPerPixel);
  }

  /// Merges a shared JPEGTables (tag 347) stream with a per-strip/tile
  /// "abbreviated" JPEG stream into one standalone JPEG, per TIFF Technical
  /// Note 2: `tables` holds SOI + shared tables (DQT/DHT/...) + EOI, and
  /// `strip` holds its own SOI + SOF/SOS/scan data + EOI; concatenating them
  /// with one of the two SOI/EOI pairs dropped reconstructs a complete image.
  static Uint8List _mergeJpegTables(Uint8List tables, Uint8List strip) {
    const soiMarker = 0xD8;
    const eoiMarker = 0xD9;
    final hasTrailingEoi = tables.length >= 2 && tables[tables.length - 2] == 0xFF && tables.last == eoiMarker;
    final tablesBody = tables.sublist(2, hasTrailingEoi ? tables.length - 2 : tables.length);
    final hasLeadingSoi = strip.length >= 2 && strip[0] == 0xFF && strip[1] == soiMarker;
    final stripBody = strip.sublist(hasLeadingSoi ? 2 : 0);

    final merged = Uint8List(2 + tablesBody.length + stripBody.length);
    merged[0] = 0xFF;
    merged[1] = soiMarker;
    merged.setRange(2, 2 + tablesBody.length, tablesBody);
    merged.setRange(2 + tablesBody.length, merged.length, stripBody);
    return merged;
  }
}
