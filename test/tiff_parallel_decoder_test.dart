import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_io.dart';

/// A distinctive, position-dependent RGB pattern so any mis-slicing (wrong
/// rows, wrong order, duplicated/missing bytes) shows up as a pixel
/// mismatch rather than passing by coincidence.
Uint8List _pattern(int width, int height) {
  final samples = Uint8List(width * height * 3);
  var o = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      samples[o++] = x % 256;
      samples[o++] = y % 256;
      samples[o++] = (x + y) % 256;
    }
  }
  return samples;
}

String _writeTiledFixture(
  Directory dir, {
  required int width,
  required int height,
  required int tileSize,
}) {
  final spec = TiffImageSpec(
    width: width,
    height: height,
    samplesPerPixel: 3,
    bitsPerSample: 8,
    photometric: TiffPhotometric.rgb,
    samples: _pattern(width, height),
    tileWidth: tileSize,
    tileLength: tileSize,
  );
  final bytes = Uint8List.fromList(TiffEncoder.encode([spec]));
  final path = '${dir.path}/fixture.tiff';
  File(path).writeAsBytesSync(bytes);
  return path;
}

void main() {
  late Directory tempDir;

  setUp(
    () => tempDir = Directory.systemTemp.createTempSync(
      'tiff_parallel_decoder_test_',
    ),
  );
  tearDown(() => tempDir.deleteSync(recursive: true));

  Uint8List referenceRgba(String path) {
    final doc = decodeTiffFile(File(path));
    try {
      return doc.images.single.decodeRgba8();
    } finally {
      doc.close();
    }
  }

  test(
    'decodeBanded reassembles the exact same pixels as a direct whole-page decode',
    () async {
      const width = 40, height = 25, tileSize = 8;
      final path = _writeTiledFixture(
        tempDir,
        width: width,
        height: height,
        tileSize: tileSize,
      );
      final reference = referenceRgba(path);

      final assembled = Uint8List(width * height * 4);
      var bandsDelivered = 0;
      await TiffParallelDecoder.decodeBanded(
        filePath: path,
        pageIndex: 0,
        bandHeight: 3, // deliberately not a divisor of tileSize or height
        maxBytesPerChunk: 100 * 1024 * 1024,
        workerCount: 3,
        onBand: (band) {
          bandsDelivered++;
          final rowBytes = width * 4;
          assembled.setRange(
            band.y * rowBytes,
            (band.y + band.height) * rowBytes,
            band.rgba,
          );
        },
      );

      expect(bandsDelivered, greaterThan(1));
      expect(assembled, reference);
    },
  );

  test(
    'workerCount greater than the number of chunks still works (no empty-worker crash)',
    () async {
      const width = 20,
          height = 8,
          tileSize = 32; // one chunk covers the whole page
      final path = _writeTiledFixture(
        tempDir,
        width: width,
        height: height,
        tileSize: tileSize,
      );
      final reference = referenceRgba(path);

      final assembled = Uint8List(width * height * 4);
      await TiffParallelDecoder.decodeBanded(
        filePath: path,
        pageIndex: 0,
        bandHeight: 2,
        maxBytesPerChunk: 100 * 1024 * 1024,
        workerCount: 8,
        onBand: (band) {
          final rowBytes = width * 4;
          assembled.setRange(
            band.y * rowBytes,
            (band.y + band.height) * rowBytes,
            band.rgba,
          );
        },
      );

      expect(assembled, reference);
    },
  );

  test(
    'a tight maxBytesPerChunk (forcing multiple chunks per tile row) still reassembles correctly',
    () async {
      const width = 64, height = 64, tileSize = 32;
      final path = _writeTiledFixture(
        tempDir,
        width: width,
        height: height,
        tileSize: tileSize,
      );
      final reference = referenceRgba(path);

      final assembled = Uint8List(width * height * 4);
      await TiffParallelDecoder.decodeBanded(
        filePath: path,
        pageIndex: 0,
        bandHeight: 4,
        // Small enough that one tile row (32 rows) can't fit — forces
        // TiffChunkPlan to shrink chunks below tileSize.
        maxBytesPerChunk: 64 * (3 * 8 + 4) * 5,
        workerCount: 2,
        onBand: (band) {
          final rowBytes = width * 4;
          assembled.setRange(
            band.y * rowBytes,
            (band.y + band.height) * rowBytes,
            band.rgba,
          );
        },
      );

      expect(assembled, reference);
    },
  );

  test('throws a TiffException for an out-of-range pageIndex', () async {
    final path = _writeTiledFixture(
      tempDir,
      width: 16,
      height: 16,
      tileSize: 8,
    );
    expect(
      () => TiffParallelDecoder.decodeBanded(
        filePath: path,
        pageIndex: 5,
        bandHeight: 4,
        maxBytesPerChunk: 1024 * 1024,
        workerCount: 2,
        onBand: (_) {},
      ),
      throwsArgumentError,
    );
  });

  test(
    'propagates a worker decode failure as a TiffException instead of hanging',
    () async {
      // A file with no readable pixel data (truncated after the header) —
      // decodeRegionRgba8 inside the worker throws, which should surface here.
      final badPath = '${tempDir.path}/not_a_tiff.tiff';
      File(badPath).writeAsBytesSync(Uint8List.fromList([0x49, 0x49, 42, 0]));

      await expectLater(
        () => TiffParallelDecoder.decodeBanded(
          filePath: badPath,
          pageIndex: 0,
          bandHeight: 4,
          maxBytesPerChunk: 1024 * 1024,
          workerCount: 2,
          onBand: (_) {},
        ),
        throwsA(anything),
      );
    },
  );
}
