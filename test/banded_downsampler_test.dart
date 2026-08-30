import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/src/optimize/banded_downsampler.dart';

/// A distinct, position-derived value per pixel/channel — chosen so any
/// row/column mixup in the banding logic shows up as a wrong value rather
/// than accidentally passing.
List<int> _samples(int width, int height) {
  final samples = <int>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      samples.addAll([(x * 3) % 256, (y * 5) % 256, (x + y) % 256]);
    }
  }
  return samples;
}

TiffImage _sourcePage(int width, int height) {
  final spec = TiffImageSpec(
    width: width,
    height: height,
    samplesPerPixel: 3,
    bitsPerSample: 8,
    photometric: TiffPhotometric.rgb,
    samples: _samples(width, height),
  );
  final bytes = TiffEncoder.encode([spec]);
  return TiffDecoder.decode(bytes).images.single;
}

/// [downsampleParallel] needs a real file on disk (each worker isolate
/// opens its own handle) rather than an already-open [TiffImage].
String _writeSourceFixture(Directory dir, int width, int height) {
  final spec = TiffImageSpec(
    width: width,
    height: height,
    samplesPerPixel: 3,
    bitsPerSample: 8,
    photometric: TiffPhotometric.rgb,
    samples: _samples(width, height),
  );
  final bytes = Uint8List.fromList(TiffEncoder.encode([spec]));
  final path = '${dir.path}/fixture.tiff';
  File(path).writeAsBytesSync(bytes);
  return path;
}

void main() {
  group('BandedDownsampler.downsample', () {
    test('matches ImageResampler.downsampleRgba8 for an exact halving', () {
      final page = _sourcePage(32, 32);
      final whole = ImageResampler.downsampleRgba8(
        page.decodeRgba8(),
        srcWidth: 32,
        srcHeight: 32,
        dstWidth: 16,
        dstHeight: 16,
      );
      final banded = BandedDownsampler.downsample(
        page,
        dstWidth: 16,
        dstHeight: 16,
      );
      expect(banded, whole);
    });

    test(
      'matches ImageResampler.downsampleRgba8 for a non-power-of-two ratio',
      () {
        final page = _sourcePage(30, 21);
        final whole = ImageResampler.downsampleRgba8(
          page.decodeRgba8(),
          srcWidth: 30,
          srcHeight: 21,
          dstWidth: 7,
          dstHeight: 5,
        );
        final banded = BandedDownsampler.downsample(
          page,
          dstWidth: 7,
          dstHeight: 5,
        );
        expect(banded, whole);
      },
    );

    test(
      'a tiny maxBandBytes (many small bands) still matches the whole-buffer result',
      () {
        final page = _sourcePage(40, 40);
        final whole = ImageResampler.downsampleRgba8(
          page.decodeRgba8(),
          srcWidth: 40,
          srcHeight: 40,
          dstWidth: 9,
          dstHeight: 9,
        );
        // One source row is 40*4=160 bytes — this forces a fresh band for
        // every single output row (sometimes every single source row).
        final banded = BandedDownsampler.downsample(
          page,
          dstWidth: 9,
          dstHeight: 9,
          maxBandBytes: 160,
        );
        expect(banded, whole);
      },
    );

    test('dst == src size returns the source pixels unchanged', () {
      final page = _sourcePage(8, 8);
      final banded = BandedDownsampler.downsample(
        page,
        dstWidth: 8,
        dstHeight: 8,
      );
      expect(banded, page.decodeRgba8());
    });

    test('rejects a dst larger than the source', () {
      final page = _sourcePage(8, 8);
      expect(
        () => BandedDownsampler.downsample(page, dstWidth: 16, dstHeight: 8),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive maxBandBytes', () {
      final page = _sourcePage(8, 8);
      expect(
        () => BandedDownsampler.downsample(
          page,
          dstWidth: 4,
          dstHeight: 4,
          maxBandBytes: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('BandedDownsampler.downsampleParallel', () {
    late Directory tempDir;
    setUp(
      () => tempDir = Directory.systemTemp.createTempSync(
        'banded_downsampler_test_',
      ),
    );
    tearDown(() => tempDir.deleteSync(recursive: true));

    test(
      'matches the sequential downsample() result for an exact halving, spread across workers',
      () async {
        const width = 32, height = 32;
        final path = _writeSourceFixture(tempDir, width, height);
        final sequential = BandedDownsampler.downsample(
          _sourcePage(width, height),
          dstWidth: 16,
          dstHeight: 16,
        );

        final parallel = await BandedDownsampler.downsampleParallel(
          filePath: path,
          dstWidth: 16,
          dstHeight: 16,
          workerCount: 4,
        );

        expect(parallel, sequential);
      },
    );

    test(
      'matches for a non-power-of-two ratio with a tight maxBandBytes (many small, interleaved bands)',
      () async {
        const width = 40, height = 40;
        final path = _writeSourceFixture(tempDir, width, height);
        final sequential = BandedDownsampler.downsample(
          _sourcePage(width, height),
          dstWidth: 9,
          dstHeight: 9,
          maxBandBytes: 160,
        );

        var bandsDelivered = 0;
        final parallel = await BandedDownsampler.downsampleParallel(
          filePath: path,
          dstWidth: 9,
          dstHeight: 9,
          maxBandBytes:
              160, // forces many bands, so they genuinely interleave across workers
          workerCount: 3,
          onBand: (bandIndex, bandCount, bandSrcRows) => bandsDelivered++,
        );

        expect(bandsDelivered, greaterThan(1));
        expect(parallel, sequential);
      },
    );

    test(
      'workerCount greater than the number of planned bands still works (no empty-worker crash)',
      () async {
        const width = 20, height = 20;
        final path = _writeSourceFixture(tempDir, width, height);
        final sequential = BandedDownsampler.downsample(
          _sourcePage(width, height),
          dstWidth: 10,
          dstHeight: 10,
        );

        final parallel = await BandedDownsampler.downsampleParallel(
          filePath: path,
          dstWidth: 10,
          dstHeight: 10,
          workerCount: 64,
        );

        expect(parallel, sequential);
      },
    );

    test(
      'dst == src size returns the source pixels unchanged, with no workers spawned',
      () async {
        const width = 8, height = 8;
        final path = _writeSourceFixture(tempDir, width, height);
        final reference = _sourcePage(width, height).decodeRgba8();

        final parallel = await BandedDownsampler.downsampleParallel(
          filePath: path,
          dstWidth: width,
          dstHeight: height,
          workerCount: 4,
        );

        expect(parallel, reference);
      },
    );

    test('rejects a dst larger than the source', () async {
      final path = _writeSourceFixture(tempDir, 8, 8);
      expect(
        () => BandedDownsampler.downsampleParallel(
          filePath: path,
          dstWidth: 16,
          dstHeight: 8,
          workerCount: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive maxBandBytes or workerCount', () async {
      final path = _writeSourceFixture(tempDir, 8, 8);
      expect(
        () => BandedDownsampler.downsampleParallel(
          filePath: path,
          dstWidth: 4,
          dstHeight: 4,
          maxBandBytes: 0,
          workerCount: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => BandedDownsampler.downsampleParallel(
          filePath: path,
          dstWidth: 4,
          dstHeight: 4,
          workerCount: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects an out-of-range pageIndex', () async {
      final path = _writeSourceFixture(tempDir, 8, 8);
      expect(
        () => BandedDownsampler.downsampleParallel(
          filePath: path,
          pageIndex: 3,
          dstWidth: 4,
          dstHeight: 4,
          workerCount: 2,
        ),
        throwsArgumentError,
      );
    });
  });
}
