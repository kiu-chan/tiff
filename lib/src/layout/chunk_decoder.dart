import 'dart:typed_data';

import '../compression/codec_registry.dart';
import '../compression/jpeg_hook.dart';
import '../compression/predictor.dart';
import '../raster/pixel_unpacker.dart';
import '../raster/raster_buffer.dart';
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
      throw const TiffException(
        'CCITT compression requires 1 bit per sample and 1 sample per pixel',
      );
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
        'Decompressed chunk is smaller than expected: got ${decompressed.length} bytes, need $expectedLength',
      );
    }

    final samples = allocateSampleBuffer(bitsPerSample, columns * rows * samplesPerPixel);
    for (var r = 0; r < rows; r++) {
      final rowStart = r * bytesPerRow;
      final rowBytes = Uint8List.sublistView(
        decompressed,
        rowStart,
        rowStart + bytesPerRow,
      );

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
        'and call TiffImageAdapter.enableJpegSupport() once before decoding',
      );
    }

    final jpegBytes = (jpegTables != null && jpegTables.isNotEmpty)
        ? _mergeJpegTables(jpegTables, compressedBytes)
        : compressedBytes;

    return decoder(
      jpegBytes,
      columns: columns,
      rows: rows,
      samplesPerPixel: samplesPerPixel,
    );
  }

  /// Whether [compressedBytes] looks like a self-contained JPEG per TIFF
  /// Technical Note 2 — its own frame header (SOF) *and* its own EOI as the
  /// last two bytes — as opposed to a fragment of one continuous scan split
  /// across chunk boundaries (see [decodeStitchedJpegChunks]).
  ///
  /// Both halves matter: a chunk can have an SOF yet still not be
  /// independently decodable — an encoder that splits one scan across
  /// chunks typically only omits the SOF from the *later* chunks, but the
  /// *first* chunk (SOF and all) is just as much a fragment, since its
  /// entropy data has nowhere near an EOI of its own. Checking the trailing
  /// EOI catches that case; checking for an SOF at all catches every other
  /// chunk that has neither.
  ///
  /// [StripLayout]/[TileLayout] call this *before* attempting a normal
  /// per-chunk decode, rather than reacting to whatever exception a failed
  /// decode happens to throw — a self-contained chunk that fails to decode
  /// for some *other* reason (corrupt data, a dimension mismatch, ...)
  /// should surface that error directly instead of being misread as "needs
  /// stitching" and merged with unrelated chunks — which, for a page whose
  /// chunks really are all independent, self-contained JPEGs, would corrupt
  /// perfectly good chunks by concatenating multiple real frames into one
  /// stream.
  static bool isSelfContainedJpeg(Uint8List compressedBytes) {
    if (compressedBytes.length < 2 ||
        compressedBytes[compressedBytes.length - 2] != 0xFF ||
        compressedBytes[compressedBytes.length - 1] != 0xD9) {
      return false;
    }
    return _hasFrameHeader(compressedBytes);
  }

  static bool _hasFrameHeader(Uint8List compressedBytes) {
    var i = 0;
    while (i + 1 < compressedBytes.length) {
      if (compressedBytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = compressedBytes[i + 1];
      if (marker == 0x00 || marker == 0xFF) {
        // Byte-stuffed 0xFF within entropy data, or a fill byte — not a
        // marker at all.
        i += 1;
        continue;
      }
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        // SOI, TEM, or a restart marker — standalone, no length field.
        i += 2;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) {
        // EOI or SOS reached with no SOF seen first.
        return false;
      }
      if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC) {
        return true;
      }
      // Every other marker (APPn, DQT, DHT, COM, ...) is followed by a
      // 2-byte big-endian length (including the length field itself, but
      // not the marker) — skip the whole segment rather than scanning its
      // payload byte-by-byte, which could contain a stray 0xFF that isn't
      // actually a marker.
      if (i + 3 >= compressedBytes.length) return false;
      final segmentLength =
          (compressedBytes[i + 2] << 8) | compressedBytes[i + 3];
      if (segmentLength < 2) return false;
      i += 2 + segmentLength;
    }
    return false;
  }

  /// Decodes a whole page's worth of JPEG-compressed chunks as *one*
  /// continuous JPEG stream instead of independently per chunk — the
  /// fallback [StripLayout]/[TileLayout] reach for when a chunk fails to
  /// decode on its own (see their doc comments): most JPEG-in-TIFF encoders
  /// write each strip/tile as a self-contained JPEG per TIFF Technical
  /// Note 2, but some instead split a single JPEG scan across chunk
  /// boundaries with no per-chunk SOF (sometimes not even a per-chunk SOI)
  /// — those chunks only make sense concatenated back into one stream.
  static List<int> decodeStitchedJpegChunks({
    required List<Uint8List> chunks,
    required int rows,
    required int columns,
    required int samplesPerPixel,
    required Uint8List? jpegTables,
  }) {
    final decoder = JpegCodecHook.decoder;
    if (decoder == null) {
      throw const TiffException(
        'JPEG-compressed TIFF data needs a JPEG decoder — import package:tiff/tiff_image_adapter.dart '
        'and call TiffImageAdapter.enableJpegSupport() once before decoding',
      );
    }
    return decoder(
      _stitchJpegStream(chunks, jpegTables),
      columns: columns,
      rows: rows,
      samplesPerPixel: samplesPerPixel,
    );
  }

  /// Merges a shared JPEGTables (tag 347) stream with a per-strip/tile
  /// "abbreviated" JPEG stream into one standalone JPEG, per TIFF Technical
  /// Note 2: `tables` holds SOI + shared tables (DQT/DHT/...) + EOI, and
  /// `strip` holds its own SOI + SOF/SOS/scan data + EOI; concatenating them
  /// with one of the two SOI/EOI pairs dropped reconstructs a complete image.
  static Uint8List _mergeJpegTables(Uint8List tables, Uint8List strip) =>
      _stitchJpegStream([strip], tables);

  /// Reassembles one continuous JPEG stream (SOI + optional shared tables +
  /// every chunk's own bytes, in order, + EOI) out of [chunks] — an
  /// abbreviated JPEGTables stream (if any) and each chunk's own SOI/EOI
  /// markers are stripped before concatenating, since only the *outermost*
  /// SOI/EOI of the reassembled stream should remain; everything between
  /// them (tables, frame/scan headers, entropy-coded data, restart markers)
  /// is kept as-is and simply appended in order.
  static Uint8List _stitchJpegStream(
    List<Uint8List> chunks,
    Uint8List? jpegTables,
  ) {
    final bodies = <Uint8List>[
      if (jpegTables != null && jpegTables.isNotEmpty)
        _stripSoiEoi(jpegTables),
      for (final chunk in chunks) _stripSoiEoi(chunk),
    ];

    var total = 4; // outermost SOI + EOI
    for (final body in bodies) {
      total += body.length;
    }
    final stitched = Uint8List(total);
    stitched[0] = 0xFF;
    stitched[1] = 0xD8; // SOI
    var offset = 2;
    for (final body in bodies) {
      stitched.setRange(offset, offset + body.length, body);
      offset += body.length;
    }
    stitched[offset] = 0xFF;
    stitched[offset + 1] = 0xD9; // EOI
    return stitched;
  }

  static Uint8List _stripSoiEoi(Uint8List bytes) {
    const soiMarker = 0xD8;
    const eoiMarker = 0xD9;
    final hasLeadingSoi =
        bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == soiMarker;
    final start = hasLeadingSoi ? 2 : 0;
    final hasTrailingEoi =
        bytes.length - start >= 2 &&
        bytes[bytes.length - 2] == 0xFF &&
        bytes.last == eoiMarker;
    final end = hasTrailingEoi ? bytes.length - 2 : bytes.length;
    return bytes.sublist(start, end);
  }
}
