import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_io.dart';

import 'support/tiff_fixture_builder.dart';

void main() {
  group('FileByteSource', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tiff_io_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('reads bytes matching the file content across window boundaries', () {
      // Large enough to force the source's internal window to be refilled
      // more than once as we read around in it.
      final content = Uint8List.fromList(
        List.generate(200000, (i) => i & 0xFF),
      );
      final file = File('${tempDir.path}/data.bin')..writeAsBytesSync(content);

      final source = FileByteSource.open(file);
      addTearDown(source.close);

      expect(source.length, content.length);
      expect(source.readBytes(0, 10), content.sublist(0, 10));
      expect(source.readBytes(100, 50), content.sublist(100, 150));
      // Jump far ahead, forcing a window refill.
      expect(source.readBytes(150000, 100), content.sublist(150000, 150100));
      // Jump back, forcing another refill.
      expect(source.readBytes(500, 20), content.sublist(500, 520));
      // A single read larger than the default window size.
      expect(source.readBytes(0, 90000), content.sublist(0, 90000));
    });

    test('throws when reading past the end of the file', () {
      final file = File('${tempDir.path}/small.bin')
        ..writeAsBytesSync(Uint8List(10));
      final source = FileByteSource.open(file);
      addTearDown(source.close);

      expect(() => source.readBytes(5, 10), throwsA(isA<TiffException>()));
    });

    test('decodeTiffFile decodes the same content as decoding from memory', () {
      final pixelData = Uint8List.fromList([10, 20, 30, 40]);
      final builder = TiffFixtureBuilder()
        ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
        ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
        ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
        ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [4])
        ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
        ..addTag(TiffTagId.rowsPerStrip, TiffTagType.tLong, [2])
        ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [4])
        ..setPixelData(pixelData);
      final bytes = builder.build();

      final file = File('${tempDir.path}/image.tif')..writeAsBytesSync(bytes);
      final fileDoc = decodeTiffFile(file);
      addTearDown(fileDoc.close);

      final memoryDoc = TiffDecoder.decode(bytes);

      expect(
        fileDoc.images.single.decode().samples,
        memoryDoc.images.single.decode().samples,
      );
      expect(
        fileDoc.images.single.metadata.width,
        memoryDoc.images.single.metadata.width,
      );
    });
  });
}
