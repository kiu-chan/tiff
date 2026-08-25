import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/src/compression/ccitt/ccitt_codec.dart';
import 'package:tiff/src/compression/ccitt/ccitt_tables.dart';

import 'support/tiff_fixture_builder.dart';

/// Reconstructs the exact bit pattern for a code table entry, mirroring the
/// decoder's own index<->code-window math in reverse. This lets tests build
/// precise CCITT bitstreams without hand-deriving bit strings — the tables
/// themselves are verified separately (byte-for-byte against a trusted
/// reference), so driving both the test vectors and the decoder from the
/// same tables is a legitimate way to exercise the decode *algorithm*
/// (mode/run parsing, pixel placement, byte packing).
String _bitsFor(
  List<List<int>> table,
  int value,
  int Function(int index) codeForIndex,
  int windowBits,
) {
  for (var idx = 0; idx < table.length; idx++) {
    final entry = table[idx];
    if (entry[0] <= 0 || entry[1] != value) continue;
    final full = codeForIndex(idx).toRadixString(2).padLeft(windowBits, '0');
    return full.substring(0, entry[0]);
  }
  throw StateError('no table entry for value $value');
}

String modeBits(int mode) => _bitsFor(twoDimTable, mode, (i) => i, 7);
String whiteBits(int run) {
  try {
    return _bitsFor(whiteTable1, run, (i) => i, 12);
  } on StateError {
    return _bitsFor(whiteTable2, run, (i) => i << 3, 12);
  }
}

String blackBits(int run) {
  try {
    return _bitsFor(blackTable1, run, (i) => i, 13);
  } on StateError {
    try {
      return _bitsFor(blackTable2, run, (i) => (i + 64) << 1, 13);
    } on StateError {
      return _bitsFor(blackTable3, run, (i) => i << 7, 13);
    }
  }
}

/// Packs a bit string (MSB-first) into bytes, zero-padding the final byte.
Uint8List packBits(String bits) {
  final byteCount = (bits.length + 7) ~/ 8;
  final out = Uint8List(byteCount);
  for (var i = 0; i < bits.length; i++) {
    if (bits[i] == '1') {
      out[i ~/ 8] |= 0x80 >> (i % 8);
    }
  }
  return out;
}

void main() {
  group('CCITT Group 4 (T.6) decode', () {
    test(
      'single all-white row (trivial vertical-mode-0 against the imaginary white reference)',
      () {
        final bits = modeBits(
          twoDimVert0,
        ); // matches the all-white imaginary reference line exactly
        final out = CcittCodec.decode(4, packBits(bits), columns: 8, rows: 1);
        expect(out, [0x00]);
      },
    );

    test('single all-black row via horizontal mode', () {
      final bits = modeBits(twoDimHoriz) + whiteBits(0) + blackBits(8);
      final out = CcittCodec.decode(4, packBits(bits), columns: 8, rows: 1);
      expect(out, [0xff]);
    });

    test('row with a run of white then black via horizontal mode', () {
      // 8 columns: 3 white pixels then 5 black -> 0b00011111 = 0x1f
      final bits = modeBits(twoDimHoriz) + whiteBits(3) + blackBits(5);
      final out = CcittCodec.decode(4, packBits(bits), columns: 8, rows: 1);
      expect(out, [0x1f]);
    });

    test(
      'second row uses vertical mode against a non-trivial reference line',
      () {
        // Row 0: horizontal mode, white(3) black(5) -> 00011111
        final row0 = modeBits(twoDimHoriz) + whiteBits(3) + blackBits(5);
        // Row 1: identical to row 0 -> a single V0 reproduces every transition.
        final row1 = modeBits(twoDimVert0) + modeBits(twoDimVert0);
        final out = CcittCodec.decode(
          4,
          packBits(row0 + row1),
          columns: 8,
          rows: 2,
        );
        expect(out, [0x1f, 0x1f]);
      },
    );

    test(
      'vertical mode with a +1 offset from the reference transition (VR1)',
      () {
        // Row 0: white(3) black(5) -> transitions at columns 3 and 8.
        final row0 = modeBits(twoDimHoriz) + whiteBits(3) + blackBits(5);
        // Row 1: first transition shifts one column right (VR1: 3+1=4), second
        // transition stays coincident (V0) -> white(4) black(4) -> 0b00001111.
        final row1 = modeBits(twoDimVertR1) + modeBits(twoDimVert0);
        final out = CcittCodec.decode(
          4,
          packBits(row0 + row1),
          columns: 8,
          rows: 2,
        );
        expect(out, [0x1f, 0x0f]);
      },
    );

    test('throws when the stream runs out before the declared row count', () {
      final bits = modeBits(twoDimVert0);
      expect(
        () => CcittCodec.decode(4, packBits(bits), columns: 8, rows: 5),
        throwsA(isA<TiffException>()),
      );
    });
  });

  group('CCITT Group 3 1D (Modified Huffman) decode', () {
    test('single row of white(3) black(5)', () {
      final bits = whiteBits(3) + blackBits(5);
      final out = CcittCodec.decode(2, packBits(bits), columns: 8, rows: 1);
      expect(out, [0x1f]);
    });

    test('a row spanning two bytes: white(10) black(6)', () {
      final bits = whiteBits(10) + blackBits(6);
      final out = CcittCodec.decode(2, packBits(bits), columns: 16, rows: 1);
      // 10 white bits then 6 black bits: 0000000000 111111 -> pad 0 more zero
      expect(out, [0x00, 0x3f]);
    });
  });

  group('CCITT Group 3 2D mixed (T4Options bit 0) decode', () {
    test('a 1D-tagged line following the leading EOL', () {
      const eol = '000000000001';
      // Per the tag-bit convention ported from the reference decoder:
      // 1 => this line is 1D-coded, 0 => 2D-coded.
      const oneDTag = '1';
      final bits = eol + oneDTag + (whiteBits(3) + blackBits(5));
      final out = CcittCodec.decode(
        3,
        packBits(bits),
        columns: 8,
        rows: 1,
        t4Options: 0x1,
      );
      expect(out, [0x1f]);
    });
  });

  group('CcittCodec option validation', () {
    test('rejects T.4 uncompressed mode', () {
      expect(
        () => CcittCodec.decode(
          3,
          Uint8List(0),
          columns: 8,
          rows: 1,
          t4Options: 0x2,
        ),
        throwsA(isA<TiffException>()),
      );
    });

    test('rejects T.6 uncompressed mode', () {
      expect(
        () => CcittCodec.decode(
          4,
          Uint8List(0),
          columns: 8,
          rows: 1,
          t6Options: 0x2,
        ),
        throwsA(isA<TiffException>()),
      );
    });
  });

  group('End-to-end TIFF decode with CCITT Group 4', () {
    test('decodes a small bilevel image through the full pipeline', () {
      // 8x2 image: row0 = white(3)+black(5), row1 identical (single V0 x2).
      final row0 = modeBits(twoDimHoriz) + whiteBits(3) + blackBits(5);
      final row1 = modeBits(twoDimVert0) + modeBits(twoDimVert0);
      final pixelData = packBits(row0 + row1);

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [0])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tShort, [2])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          pixelData.length,
        ])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [
          pixelData.length,
        ])
        ..setPixelData(pixelData);

      final doc = TiffDecoder.decode(builder.build());
      final image = doc.images.single;
      final raster = image.decode();
      // WhiteIsZero: sample 0 = white, 1 = black.
      expect(raster.samples, [0, 0, 0, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1]);
    });

    test('rejects CCITT data declared with more than 1 bit/sample', () {
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [0])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [1])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [1])
        ..setPixelData(Uint8List.fromList([0x80]));

      final doc = TiffDecoder.decode(builder.build());
      expect(() => doc.images.single.decode(), throwsA(isA<TiffException>()));
    });
  });
}
