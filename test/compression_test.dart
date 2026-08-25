import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/src/compression/lzw_codec.dart';
import 'package:tiff/src/compression/packbits_codec.dart';
import 'package:tiff/src/compression/predictor.dart';

import 'support/tiff_fixture_builder.dart';

void main() {
  group('LzwCodec (unit)', () {
    test('round-trips a short repeating sequence', () {
      final input = Uint8List.fromList([7, 7, 7, 8, 8, 7, 7, 6, 6]);
      final encoded = LzwCodec.encode(input);
      final decoded = LzwCodec.decode(encoded);
      expect(decoded, input);
    });

    test('round-trips data large enough to grow past 9-bit codes', () {
      // A pseudo-random-ish but deterministic sequence with enough distinct
      // substrings to push the dictionary past the 510-entry "early change"
      // boundary into 10-bit codes.
      final input = Uint8List.fromList(
        List.generate(2000, (i) => (i * 37 + i ~/ 7) & 0xFF),
      );
      final encoded = LzwCodec.encode(input);
      final decoded = LzwCodec.decode(encoded);
      expect(decoded, input);
    });

    test('round-trips a single repeated byte (long run)', () {
      final input = Uint8List.fromList(List.filled(500, 42));
      final decoded = LzwCodec.decode(LzwCodec.encode(input));
      expect(decoded, input);
    });

    test(
      'decodes a real "old-style" (LSB-first, no early change) LZW TIFF',
      () {
        // quad-lzw-compat.tiff, from libtiff's own test suite, is a regression
        // fixture specifically for the legacy pre-TIFF6 LZW packing that a
        // handful of old encoders wrote (and that libtiff itself special-cases
        // as "LZW_COMPAT"). Expected pixel values below were cross-checked
        // against macOS's own ImageIO TIFF decoder (via `sips`) rendering the
        // same file identically.
        final bytes = File(
          'test/fixtures/quad-lzw-compat.tiff',
        ).readAsBytesSync();
        final page = TiffDecoder.decode(bytes).images.single;
        final raster = page.decode();

        int r(int x, int y) => raster.sampleAt(x, y, 0);
        int g(int x, int y) => raster.sampleAt(x, y, 1);
        int b(int x, int y) => raster.sampleAt(x, y, 2);

        expect((r(0, 0), g(0, 0), b(0, 0)), (0, 0, 0)); // black background
        expect((r(250, 90), g(250, 90), b(250, 90)), (101, 48, 88));
        expect((r(350, 60), g(350, 60), b(350, 60)), (208, 6, 202));
        expect((r(450, 300), g(450, 300), b(450, 300)), (0, 140, 188));
      },
    );
  });

  group('PackBitsCodec (unit)', () {
    test('decodes a literal run followed by a repeat run', () {
      // Literal run of 3 bytes [1,2,3], then a repeat of 0xAA x4.
      final input = Uint8List.fromList([2, 1, 2, 3, (256 - 3) & 0xFF, 0xAA]);
      expect(PackBitsCodec.decode(input), [1, 2, 3, 0xAA, 0xAA, 0xAA, 0xAA]);
    });

    test('treats -128 as a no-op', () {
      final input = Uint8List.fromList([128]); // 128 as unsigned == -128 signed
      expect(PackBitsCodec.decode(input), isEmpty);
    });
  });

  group('Predictor (unit)', () {
    test('undoes 8-bit horizontal differencing for a single-channel row', () {
      final original = Uint8List.fromList([10, 15, 12, 40]);
      final diffed = Uint8List.fromList([
        10,
        5,
        253,
        28,
      ]); // 15-10=5, 12-15=-3, 40-12=28
      Predictor.undoHorizontalDifferencing(
        rowBytes: diffed,
        bitsPerSample: 8,
        samplesPerPixel: 1,
        endian: Endian.little,
      );
      expect(diffed, original);
    });

    test('undoes 8-bit horizontal differencing across multiple channels', () {
      // 2 pixels, 3 samples/pixel (RGB): (10,20,30), (12,25,33)
      final original = Uint8List.fromList([10, 20, 30, 12, 25, 33]);
      final diffed = Uint8List.fromList([10, 20, 30, 2, 5, 3]);
      Predictor.undoHorizontalDifferencing(
        rowBytes: diffed,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        endian: Endian.little,
      );
      expect(diffed, original);
    });
  });

  group('End-to-end strip decode with compression', () {
    test('decodes an LZW-compressed strip', () {
      final raw = Uint8List.fromList(List.generate(16, (i) => (i * 17) & 0xFF));
      final compressed = LzwCodec.encode(raw);

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [5])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          compressed.length,
        ])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [4])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [
          compressed.length,
        ])
        ..setPixelData(compressed);

      final raster = TiffDecoder.decode(builder.build()).images.single.decode();
      expect(raster.samples, raw);
    });

    test('decodes a PackBits-compressed strip', () {
      const raw = [1, 2, 3, 4, 0xAA, 0xAA, 0xAA, 0xAA];
      // Literal run [1,2,3,4] then repeat 0xAA x4.
      final compressed = Uint8List.fromList([
        3,
        1,
        2,
        3,
        4,
        (256 - 3) & 0xFF,
        0xAA,
      ]);

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [32773])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          compressed.length,
        ])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [1])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [
          compressed.length,
        ])
        ..setPixelData(compressed);

      final raster = TiffDecoder.decode(builder.build()).images.single.decode();
      expect(raster.samples, raw);
    });

    test('decodes a Deflate-compressed strip', () {
      final raw = Uint8List.fromList(List.generate(16, (i) => i * 5));
      final compressed = Uint8List.fromList(const ZLibEncoder().encode(raw));

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [4])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          compressed.length,
        ])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [4])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [
          compressed.length,
        ])
        ..setPixelData(compressed);

      final raster = TiffDecoder.decode(builder.build()).images.single.decode();
      expect(raster.samples, raw);
    });

    test('decodes an uncompressed strip with a horizontal predictor', () {
      // 2x2, RGB, samples: (10,20,30)(12,25,33) / (14,20,30)(16,25,33)
      const row0 = [10, 20, 30, 12, 25, 33];
      const row1 = [14, 20, 30, 16, 25, 33];
      final diffedRow0 = [10, 20, 30, 2, 5, 3];
      final diffedRow1 = [14, 20, 30, 2, 5, 3];
      final pixelData = Uint8List.fromList([...diffedRow0, ...diffedRow1]);

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8, 8, 8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.predictor, TiffTagType.tShort, [2])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          pixelData.length,
        ])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [2])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [
          pixelData.length,
        ])
        ..setPixelData(pixelData);

      final raster = TiffDecoder.decode(builder.build()).images.single.decode();
      expect(raster.samples, [...row0, ...row1]);
    });
  });
}
