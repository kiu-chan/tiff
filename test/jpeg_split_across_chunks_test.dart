import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_image_adapter.dart';

import 'support/tiff_fixture_builder.dart';

/// Most JPEG-in-TIFF encoders write each strip/tile as a self-contained
/// JPEG (TIFF Technical Note 2): every chunk has its own SOI/SOF/SOS/EOI,
/// optionally sharing a JPEGTables (tag 347) stream for the quantization/
/// Huffman tables. Some encoders instead treat the whole page as *one*
/// continuous JPEG scan and simply chop its bytes into chunk-sized pieces
/// for storage — only the first chunk then has a frame header (SOF); later
/// chunks are pure continuation entropy data. Decoding a later chunk on its
/// own used to surface as `package:image`'s
/// `ImageException: Only single frame JPEGs supported` (it walks the bytes
/// handed to it and never finds a frame header) — these tests build exactly
/// that shape and check it decodes correctly instead.
void main() {
  setUpAll(() => TiffImageAdapter.enableJpegSupport());

  img.Image gradient(int width, int height, {int offset = 0}) {
    final image = img.Image(width: width, height: height, numChannels: 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(x, y, (x * 255 ~/ width + offset) % 256, (y * 255 ~/ height) % 256, 128);
      }
    }
    return image;
  }

  group('a JPEG scan split across strips', () {
    test('decode() reassembles it and matches decoding the original JPEG whole', () {
      final source = gradient(16, 8);
      final jpegBytes = Uint8List.fromList(img.encodeJpg(source, quality: 90));
      // Splits the single JPEG stream roughly in half — the second half has
      // no SOI/SOF of its own, the shape that makes a standalone per-strip
      // decode fail.
      final splitAt = jpegBytes.length ~/ 2;

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [16])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [4])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [splitAt, jpegBytes.length - splitAt])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [splitAt, jpegBytes.length - splitAt])
        ..setPixelData(jpegBytes);

      final page = TiffDecoder.decode(builder.build()).images.single;
      final decoded = page.decode();

      final reference = img.decodeJpg(jpegBytes)!.getBytes(order: img.ChannelOrder.rgb);
      expect(decoded.samples, reference);
    });

    test('decodeRegion() still returns the right pixels, not just decode()', () {
      final source = gradient(16, 8);
      final jpegBytes = Uint8List.fromList(img.encodeJpg(source, quality: 90));
      final splitAt = jpegBytes.length ~/ 3; // an uneven split, for good measure

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [16])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [4])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [splitAt, jpegBytes.length - splitAt])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [splitAt, jpegBytes.length - splitAt])
        ..setPixelData(jpegBytes);

      final page = TiffDecoder.decode(builder.build()).images.single;
      final region = const TiffRegion(x: 4, y: 2, width: 6, height: 5);
      final decoded = page.decodeRegion(region);

      final fullReference = img.decodeJpg(jpegBytes)!.getBytes(order: img.ChannelOrder.rgb);
      final expected = Uint8List(region.width * region.height * 3);
      for (var r = 0; r < region.height; r++) {
        final srcStart = ((region.y + r) * 16 + region.x) * 3;
        final destStart = r * region.width * 3;
        expected.setRange(destStart, destStart + region.width * 3, fullReference, srcStart);
      }
      expect(decoded.samples, expected);
    });

    test('a shared JPEGTables stream still merges in correctly for a split scan', () {
      final source = gradient(12, 12);
      final full = Uint8List.fromList(img.encodeJpg(source, quality: 92));

      // Build an "abbreviated" strip stream (SOI + DQT/DHT tables + EOI,
      // sans SOF/SOS/scan data) by cutting everything from SOF (0xFFC0)
      // onward out of the full JPEG, matching how TIFF Technical Note 2's
      // shared JPEGTables tag is meant to look.
      var sofStart = -1;
      for (var i = 0; i < full.length - 1; i++) {
        if (full[i] == 0xFF && full[i + 1] == 0xC0) {
          sofStart = i;
          break;
        }
      }
      expect(sofStart, greaterThan(0), reason: 'test JPEG must contain a baseline SOF0 marker');
      final jpegTables = Uint8List.fromList([...full.sublist(0, sofStart), 0xFF, 0xD9]);
      final abbreviatedStrip = full.sublist(sofStart);
      final splitAt = abbreviatedStrip.length ~/ 2;

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [12])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [12])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [6])
        ..addBytesTag(TiffTagId.jpegTables, TiffTagType.tUndefined, jpegTables)
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [
          splitAt,
          abbreviatedStrip.length - splitAt,
        ])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [
          splitAt,
          abbreviatedStrip.length - splitAt,
        ])
        ..setPixelData(abbreviatedStrip);

      final page = TiffDecoder.decode(builder.build()).images.single;
      final decoded = page.decode();

      final reference = img.decodeJpg(full)!.getBytes(order: img.ChannelOrder.rgb);
      expect(decoded.samples, reference);
    });
  });

  group('independent, self-contained per-tile JPEGs (e.g. a real scanner file)', () {
    test('one tile failing for an unrelated reason surfaces its own error, not a stitching artifact', () {
      // Regression test: earlier versions of the split-scan fallback above
      // reacted to *any* JPEG decode failure by reassembling every chunk of
      // the page into one stream and decoding that instead. For a page
      // like this one — every tile independently self-contained, exactly
      // what real whole-slide-image scanners write — that's wrong on two
      // counts: it hides the real error, and concatenating multiple
      // genuinely complete JPEGs produces multiple real SOF markers, which
      // package:image rejects with "Duplicate JPG frame data found." This
      // checks the fix: a self-contained tile that fails to decode (here,
      // deliberately encoded at the wrong size for its declared tile
      // dimensions) surfaces its own, direct error instead.
      final tileA = gradient(8, 8);
      final tileAJpeg = Uint8List.fromList(img.encodeJpg(tileA, quality: 90));
      final tileBWrongSize = gradient(4, 4);
      final tileBJpeg = Uint8List.fromList(img.encodeJpg(tileBWrongSize, quality: 90));
      final pixelData = Uint8List.fromList([...tileAJpeg, ...tileBJpeg]);

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [16])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.tileWidth, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.tileLength, TiffTagType.tShort, [8])
        ..addTileOffsetsTag(TiffTagId.tileOffsets, TiffTagType.tLong, [tileAJpeg.length, tileBJpeg.length])
        ..addTag(TiffTagId.tileByteCounts, TiffTagType.tLong, [tileAJpeg.length, tileBJpeg.length])
        ..setPixelData(pixelData);

      final page = TiffDecoder.decode(builder.build()).images.single;

      expect(
        () => page.decode(),
        throwsA(
          isA<TiffException>().having(
            (e) => e.message,
            'message',
            allOf(contains('4x4'), isNot(contains('frame'))),
          ),
        ),
      );
    });

    test('every tile still decodes independently when all are well-formed', () {
      final tileA = gradient(8, 8);
      final tileAJpeg = Uint8List.fromList(img.encodeJpg(tileA, quality: 90));
      final tileB = gradient(8, 8, offset: 100);
      final tileBJpeg = Uint8List.fromList(img.encodeJpg(tileB, quality: 90));
      final pixelData = Uint8List.fromList([...tileAJpeg, ...tileBJpeg]);

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [16])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.tileWidth, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.tileLength, TiffTagType.tShort, [8])
        ..addTileOffsetsTag(TiffTagId.tileOffsets, TiffTagType.tLong, [tileAJpeg.length, tileBJpeg.length])
        ..addTag(TiffTagId.tileByteCounts, TiffTagType.tLong, [tileAJpeg.length, tileBJpeg.length])
        ..setPixelData(pixelData);

      final page = TiffDecoder.decode(builder.build()).images.single;
      final decoded = page.decode();

      final referenceA = img.decodeJpg(tileAJpeg)!.getBytes(order: img.ChannelOrder.rgb);
      final referenceB = img.decodeJpg(tileBJpeg)!.getBytes(order: img.ChannelOrder.rgb);
      // Each 8-row-tall, 8-wide tile occupies half of every row of the
      // 16-wide page — reassemble the expected interleaved samples the
      // same way TileLayout does, rather than comparing whole buffers.
      final expected = Uint8List(16 * 8 * 3);
      for (var y = 0; y < 8; y++) {
        expected.setRange((y * 16) * 3, (y * 16 + 8) * 3, referenceA, y * 8 * 3);
        expected.setRange((y * 16 + 8) * 3, (y * 16 + 16) * 3, referenceB, y * 8 * 3);
      }
      expect(decoded.samples, expected);
    });
  });

  group('a JPEG scan split across tiles', () {
    test('decode() reassembles it and matches decoding the original JPEG whole', () {
      final source = gradient(16, 16);
      final jpegBytes = Uint8List.fromList(img.encodeJpg(source, quality: 90));
      final splitAt = jpegBytes.length ~/ 2;

      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [16])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [16])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [3])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [7])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.tileWidth, TiffTagType.tShort, [16])
        ..addTag(TiffTagId.tileLength, TiffTagType.tShort, [8])
        ..addTileOffsetsTag(TiffTagId.tileOffsets, TiffTagType.tLong, [splitAt, jpegBytes.length - splitAt])
        ..addTag(TiffTagId.tileByteCounts, TiffTagType.tLong, [splitAt, jpegBytes.length - splitAt])
        ..setPixelData(jpegBytes);

      final page = TiffDecoder.decode(builder.build()).images.single;
      final decoded = page.decode();

      final reference = img.decodeJpg(jpegBytes)!.getBytes(order: img.ChannelOrder.rgb);
      expect(decoded.samples, reference);
    });
  });
}
