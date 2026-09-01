import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

/// Builds a small strip-organized (non-tiled) source page — an 8x8 RGB
/// gradient — the kind of plain source [TiffDisplayOptimizer] is meant to
/// restructure.
TiffImage _sourcePage({int width = 8, int height = 8}) {
  final spec = _sourceSpec(width: width, height: height);
  final bytes = TiffEncoder.encode([spec]);
  return TiffDecoder.decode(bytes).images.single;
}

TiffImageSpec _sourceSpec({int width = 8, int height = 8}) {
  final samples = <int>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      samples.addAll([(x * 255 ~/ width), (y * 255 ~/ height), 128]);
    }
  }
  return TiffImageSpec(
    width: width,
    height: height,
    samplesPerPixel: 3,
    bitsPerSample: 8,
    photometric: TiffPhotometric.rgb,
    samples: samples,
  );
}

/// [TiffDisplayOptimizer.optimizeLargeSourcePyramidLevelsParallel] needs a
/// real file on disk (each worker isolate opens its own handle) rather than
/// an already-open [TiffImage].
String _writeSourceFixture(Directory dir, {int width = 8, int height = 8}) {
  final bytes = Uint8List.fromList(
    TiffEncoder.encode([_sourceSpec(width: width, height: height)]),
  );
  final path = '${dir.path}/fixture.tiff';
  File(path).writeAsBytesSync(bytes);
  return path;
}

void main() {
  group('TiffDisplayOptimizer.optimize', () {
    test('tiledOnly re-tiles at native resolution with no extra pages', () {
      final source = _sourcePage(width: 8, height: 8);
      expect(source.metadata.isTiled, isFalse);

      final optimized = TiffDecoder.decode(
        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.tiledOnly,
          tileSize: 4,
        ),
      );

      expect(optimized.images, hasLength(1));
      final page = optimized.images.single;
      expect(page.metadata.isTiled, isTrue);
      expect(page.metadata.width, 8);
      expect(page.metadata.height, 8);
      expect(page.metadata.tileWidth, 4);
      expect(page.metadata.tileLength, 4);
    });

    test('tiledOnly preserves pixel content (RGB, alpha dropped)', () {
      final source = _sourcePage(width: 8, height: 8);
      final sourceRgba = source.decodeRgba8();

      final optimized = TiffDecoder.decode(
        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.tiledOnly,
          tileSize: 4,
        ),
      );
      final optimizedRgba = optimized.images.single.decodeRgba8();

      for (var i = 0; i < sourceRgba.length; i += 4) {
        expect(optimizedRgba[i], sourceRgba[i], reason: 'R at pixel ${i ~/ 4}');
        expect(
          optimizedRgba[i + 1],
          sourceRgba[i + 1],
          reason: 'G at pixel ${i ~/ 4}',
        );
        expect(
          optimizedRgba[i + 2],
          sourceRgba[i + 2],
          reason: 'B at pixel ${i ~/ 4}',
        );
      }
    });

    test(
      'tiledPyramid appends progressively halved, tiled rungs down to minPyramidDimension',
      () {
        final source = _sourcePage(width: 32, height: 32);

        final optimized = TiffDecoder.decode(
          TiffDisplayOptimizer.optimize(
            source,
            mode: TiffOptimizationMode.tiledPyramid,
            tileSize: 16,
            minPyramidDimension: 8,
          ),
        );

        // 32 -> 16 -> 8 (stop: <= minPyramidDimension), 3 rungs.
        expect(optimized.images, hasLength(3));
        final dims = optimized.images
            .map((i) => (i.metadata.width, i.metadata.height))
            .toList();
        expect(dims, [(32, 32), (16, 16), (8, 8)]);
        for (final image in optimized.images) {
          expect(image.metadata.isTiled, isTrue);
        }
      },
    );

    test('tiledPyramid keeps a non-square page proportional across rungs', () {
      final source = _sourcePage(width: 32, height: 8);

      final optimized = TiffDecoder.decode(
        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.tiledPyramid,
          tileSize: 16,
          minPyramidDimension: 8,
        ),
      );

      final dims = optimized.images
          .map((i) => (i.metadata.width, i.metadata.height))
          .toList();
      expect(dims, [(32, 8), (16, 4), (8, 2)]);
    });

    test(
      'a page already at or below minPyramidDimension yields a single rung',
      () {
        final source = _sourcePage(width: 8, height: 8);

        final optimized = TiffDecoder.decode(
          TiffDisplayOptimizer.optimize(
            source,
            mode: TiffOptimizationMode.tiledPyramid,
            tileSize: 4,
            minPyramidDimension: 512,
          ),
        );

        expect(optimized.images, hasLength(1));
      },
    );

    test('a tile larger than the page is padded, not rejected', () {
      final source = _sourcePage(width: 8, height: 8);
      final optimized = TiffDecoder.decode(
        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.tiledOnly,
          tileSize: 64,
        ),
      );
      final page = optimized.images.single;
      expect(page.metadata.width, 8);
      expect(page.metadata.height, 8);
      // Decoding should still return exactly the page's own dimensions,
      // not the (padded) tile size.
      expect(page.decodeRgba8().length, 8 * 8 * 4);
    });

    test(
      'onProgress reports decode, downsample, and per-tile encode updates for every rung, ending at fraction 1.0',
      () {
        final source = _sourcePage(width: 32, height: 32);
        final progress = <TiffOptimizeProgress>[];

        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.tiledPyramid,
          tileSize: 16,
          minPyramidDimension: 8,
          onProgress: progress.add,
        );

        expect(progress, isNotEmpty);
        // 3 rungs (32 -> 16 -> 8): one whole-page decode, two downsamples, and
        // some number of per-tile encode updates per rung.
        expect(progress.every((p) => p.levelCount == 3), isTrue);
        expect(
          progress
              .where((p) => p.stage == TiffOptimizeStage.decoding)
              .map((p) => p.level),
          [0],
        );
        expect(
          progress
              .where((p) => p.stage == TiffOptimizeStage.downsampling)
              .map((p) => p.level),
          [1, 2],
        );
        expect(
          progress
              .where((p) => p.stage == TiffOptimizeStage.encoding)
              .map((p) => p.level)
              .toSet(),
          {0, 1, 2},
        );

        // fraction is monotonically non-decreasing and ends exactly at 1.0.
        for (var i = 1; i < progress.length; i++) {
          expect(
            progress[i].fraction,
            greaterThanOrEqualTo(progress[i - 1].fraction),
          );
        }
        expect(progress.last.fraction, 1.0);
        expect(progress.last.stage, TiffOptimizeStage.encoding);
        expect(progress.last.stepIndex, progress.last.stepCount);
      },
    );

    test(
      'onProgress reports a single-level encode for tiledOnly (no pyramid rungs)',
      () {
        final source = _sourcePage(width: 32, height: 32);
        final progress = <TiffOptimizeProgress>[];

        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.tiledOnly,
          tileSize: 16,
          onProgress: progress.add,
        );

        expect(progress, isNotEmpty);
        expect(
          progress.every((p) => p.levelCount == 1 && p.level == 0),
          isTrue,
        );
        expect(
          progress.where((p) => p.stage == TiffOptimizeStage.decoding),
          hasLength(1),
        );
        expect(
          progress.where((p) => p.stage == TiffOptimizeStage.downsampling),
          isEmpty,
        );
        expect(
          progress.where((p) => p.stage == TiffOptimizeStage.encoding),
          isNotEmpty,
        );
        expect(progress.last.fraction, 1.0);
      },
    );

    test(
      'pyramidLevelsOnly builds the same rungs as tiledPyramid minus the base level',
      () {
        final source = _sourcePage(width: 32, height: 32);

        final optimized = TiffDecoder.decode(
          TiffDisplayOptimizer.optimize(
            source,
            mode: TiffOptimizationMode.pyramidLevelsOnly,
            tileSize: 16,
            minPyramidDimension: 8,
          ),
        );

        // Same rungs as the tiledPyramid test above (32 -> 16 -> 8), but the
        // 32x32 base level itself is never encoded into the output.
        final dims = optimized.images
            .map((i) => (i.metadata.width, i.metadata.height))
            .toList();
        expect(dims, [(16, 16), (8, 8)]);
        for (final image in optimized.images) {
          expect(image.metadata.isTiled, isTrue);
        }
      },
    );

    test('pyramidLevelsOnly rungs match tiledPyramid rungs pixel-for-pixel', () {
      final source = _sourcePage(width: 32, height: 32);

      final pyramid = TiffDecoder.decode(
        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.tiledPyramid,
          tileSize: 16,
          minPyramidDimension: 8,
        ),
      );
      final levelsOnly = TiffDecoder.decode(
        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.pyramidLevelsOnly,
          tileSize: 16,
          minPyramidDimension: 8,
        ),
      );

      // pyramid.images[1:] are the same smaller rungs levelsOnly.images holds.
      expect(levelsOnly.images.length, pyramid.images.length - 1);
      for (var i = 0; i < levelsOnly.images.length; i++) {
        expect(
          levelsOnly.images[i].decodeRgba8(),
          pyramid.images[i + 1].decodeRgba8(),
        );
      }
    });

    test(
      'onProgress reports 2 output levels (no encode step for the base) for pyramidLevelsOnly',
      () {
        final source = _sourcePage(width: 32, height: 32);
        final progress = <TiffOptimizeProgress>[];

        TiffDisplayOptimizer.optimize(
          source,
          mode: TiffOptimizationMode.pyramidLevelsOnly,
          tileSize: 16,
          minPyramidDimension: 8,
          onProgress: progress.add,
        );

        // Output is 2 rungs (16, 8) — the 32x32 base is still decoded (level 0
        // of the decoding stage) and downsampled from, but never encoded.
        expect(progress.every((p) => p.levelCount == 2), isTrue);
        expect(
          progress
              .where((p) => p.stage == TiffOptimizeStage.encoding)
              .map((p) => p.level)
              .toSet(),
          {0, 1},
        );
        expect(progress.last.fraction, 1.0);
      },
    );

    test(
      'pyramidLevelsOnly rejects a page already at or below minPyramidDimension',
      () {
        final source = _sourcePage(width: 8, height: 8);
        expect(
          () => TiffDisplayOptimizer.optimize(
            source,
            mode: TiffOptimizationMode.pyramidLevelsOnly,
            minPyramidDimension: 512,
          ),
          throwsArgumentError,
        );
      },
    );

    group('optimizeLargeSourcePyramidLevels', () {
      test(
        'with a generous maxDirectDecodePixels, matches pyramidLevelsOnly exactly',
        () {
          final source = _sourcePage(width: 32, height: 32);

          final viaLargeSource = TiffDecoder.decode(
            TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
              source,
              tileSize: 16,
              minPyramidDimension: 8,
              maxDirectDecodePixels: 32 * 32, // fits the whole source directly
            ),
          );
          final viaPlain = TiffDecoder.decode(
            TiffDisplayOptimizer.optimize(
              source,
              mode: TiffOptimizationMode.pyramidLevelsOnly,
              tileSize: 16,
              minPyramidDimension: 8,
            ),
          );

          expect(viaLargeSource.images.length, viaPlain.images.length);
          for (var i = 0; i < viaLargeSource.images.length; i++) {
            expect(
              viaLargeSource.images[i].metadata.width,
              viaPlain.images[i].metadata.width,
            );
            expect(
              viaLargeSource.images[i].metadata.height,
              viaPlain.images[i].metadata.height,
            );
            expect(
              viaLargeSource.images[i].decodeRgba8(),
              viaPlain.images[i].decodeRgba8(),
            );
          }
        },
      );

      test(
        'a tight maxDirectDecodePixels skips rungs larger than it, starting from the first that fits',
        () {
          final source = _sourcePage(width: 64, height: 64);

          // Halving sequence from 64: 32, 16, 8. A budget of 32*32 pixels
          // rules out only the (never-produced-here) 64x64 base — the first
          // rung this produces should be 32x32, same as pyramidLevelsOnly's
          // own first rung would be.
          final optimized = TiffDecoder.decode(
            TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
              source,
              tileSize: 16,
              minPyramidDimension: 8,
              maxDirectDecodePixels: 32 * 32,
            ),
          );
          final dims = optimized.images
              .map((i) => (i.metadata.width, i.metadata.height))
              .toList();
          expect(dims, [(32, 32), (16, 16), (8, 8)]);

          // A tighter budget that also rules out 32x32 should skip straight
          // to 16x16 as the first rung — one fewer level than above.
          final tighter = TiffDecoder.decode(
            TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
              source,
              tileSize: 16,
              minPyramidDimension: 8,
              maxDirectDecodePixels: 16 * 16,
            ),
          );
          final tighterDims = tighter.images
              .map((i) => (i.metadata.width, i.metadata.height))
              .toList();
          expect(tighterDims, [(16, 16), (8, 8)]);
        },
      );

      test(
        'the first (banded) rung matches what plain box-downsampling would produce',
        () {
          final source = _sourcePage(width: 64, height: 64);

          final optimized = TiffDecoder.decode(
            TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
              source,
              tileSize: 16,
              minPyramidDimension: 8,
              maxDirectDecodePixels: 16 * 16,
              maxBandBytes:
                  64 * 4, // forces many small bands (one source row each)
            ),
          );
          final firstRung = optimized.images.first.decodeRgba8();

          // Independently derived expected first rung: BandedDownsampler is
          // documented to match a single direct ImageResampler.downsampleRgba8
          // call from the whole (here, fully in-memory) source straight to
          // the target size — not two sequential 2x halvings, which round at
          // each intermediate step and so land on slightly different values.
          final expected = ImageResampler.downsampleRgba8(
            source.decodeRgba8(),
            srcWidth: 64,
            srcHeight: 64,
            dstWidth: 16,
            dstHeight: 16,
          );
          expect(firstRung, expected);
        },
      );

      test(
        'onProgress reports multiple banded decode updates before any downsample/encode ones',
        () {
          final source = _sourcePage(width: 64, height: 64);
          final progress = <TiffOptimizeProgress>[];

          TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
            source,
            tileSize: 16,
            minPyramidDimension: 8,
            maxDirectDecodePixels: 16 * 16,
            maxBandBytes:
                64 * 4, // forces many small bands (one source row each)
            onProgress: progress.add,
          );

          final decodeUpdates = progress
              .where((p) => p.stage == TiffOptimizeStage.decoding)
              .toList();
          // 16 rows in, banded 1 source row at a time -> 16 separate updates,
          // not one opaque "decode done" call the way this used to report.
          expect(decodeUpdates.length, greaterThan(1));
          expect(decodeUpdates.map((p) => p.level), everyElement(0));
          expect(decodeUpdates.last.stepIndex, decodeUpdates.last.stepCount);

          // Every decode update comes before the first downsample/encode one.
          final firstNonDecodeIndex = progress.indexWhere(
            (p) => p.stage != TiffOptimizeStage.decoding,
          );
          expect(firstNonDecodeIndex, decodeUpdates.length);

          for (var i = 1; i < progress.length; i++) {
            expect(
              progress[i].fraction,
              greaterThanOrEqualTo(progress[i - 1].fraction),
            );
          }
          expect(progress.last.fraction, 1.0);
        },
      );

      test(
        'rejects a page already at or below minPyramidDimension, same as pyramidLevelsOnly',
        () {
          final source = _sourcePage(width: 8, height: 8);
          expect(
            () => TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
              source,
              minPyramidDimension: 512,
            ),
            throwsArgumentError,
          );
        },
      );

      test('rejects non-positive maxDirectDecodePixels/maxBandBytes', () {
        final source = _sourcePage(width: 32, height: 32);
        expect(
          () => TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
            source,
            maxDirectDecodePixels: 0,
          ),
          throwsArgumentError,
        );
        expect(
          () => TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
            source,
            maxBandBytes: 0,
          ),
          throwsArgumentError,
        );
      });

      group('optimizeLargeSourcePyramidLevelsParallel', () {
        late Directory tempDir;
        setUp(
          () => tempDir = Directory.systemTemp.createTempSync(
            'tiff_display_optimizer_test_',
          ),
        );
        tearDown(() => tempDir.deleteSync(recursive: true));

        test('matches optimizeLargeSourcePyramidLevels bit-for-bit', () async {
          const width = 64, height = 64;
          final path = _writeSourceFixture(
            tempDir,
            width: width,
            height: height,
          );
          final sequential = TiffDecoder.decode(
            TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
              _sourcePage(width: width, height: height),
              tileSize: 16,
              minPyramidDimension: 8,
              maxDirectDecodePixels: 16 * 16,
              maxBandBytes:
                  64 * 4, // forces many small, worker-interleaved bands
            ),
          );

          final parallelBytes =
              await TiffDisplayOptimizer.optimizeLargeSourcePyramidLevelsParallel(
                _sourcePage(width: width, height: height),
                path,
                tileSize: 16,
                minPyramidDimension: 8,
                maxDirectDecodePixels: 16 * 16,
                maxBandBytes: 64 * 4,
                workerCount: 4,
              );
          final parallel = TiffDecoder.decode(parallelBytes);

          expect(parallel.images.length, sequential.images.length);
          for (var i = 0; i < parallel.images.length; i++) {
            expect(
              parallel.images[i].metadata.width,
              sequential.images[i].metadata.width,
            );
            expect(
              parallel.images[i].metadata.height,
              sequential.images[i].metadata.height,
            );
            expect(
              parallel.images[i].decodeRgba8(),
              sequential.images[i].decodeRgba8(),
            );
          }
        });

        test('workerCount and maxBandBytes are both optional', () async {
          const width = 64, height = 64;
          final path = _writeSourceFixture(tempDir, width: width, height: height);
          final sequential = TiffDecoder.decode(
            TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels(
              _sourcePage(width: width, height: height),
              tileSize: 16,
              minPyramidDimension: 8,
              maxDirectDecodePixels: 16 * 16,
            ),
          );

          // Neither given — should fall back to TiffAutoDecodeBudget.recommend
          // internally rather than throwing.
          final parallelBytes = await TiffDisplayOptimizer.optimizeLargeSourcePyramidLevelsParallel(
            _sourcePage(width: width, height: height),
            path,
            tileSize: 16,
            minPyramidDimension: 8,
            maxDirectDecodePixels: 16 * 16,
          );
          final parallel = TiffDecoder.decode(parallelBytes);

          expect(parallel.images.length, sequential.images.length);
          for (var i = 0; i < parallel.images.length; i++) {
            expect(parallel.images[i].decodeRgba8(), sequential.images[i].decodeRgba8());
          }
        });

        test(
          'onProgress reports banded decode, downsample, and encode updates ending at fraction 1.0',
          () async {
            const width = 64, height = 64;
            final path = _writeSourceFixture(
              tempDir,
              width: width,
              height: height,
            );
            final progress = <TiffOptimizeProgress>[];

            await TiffDisplayOptimizer.optimizeLargeSourcePyramidLevelsParallel(
              _sourcePage(width: width, height: height),
              path,
              tileSize: 16,
              minPyramidDimension: 8,
              maxDirectDecodePixels: 16 * 16,
              maxBandBytes: 64 * 4,
              workerCount: 4,
              onProgress: progress.add,
            );

            expect(progress, isNotEmpty);
            final decodeUpdates = progress
                .where((p) => p.stage == TiffOptimizeStage.decoding)
                .toList();
            expect(decodeUpdates.length, greaterThan(1));
            for (var i = 1; i < progress.length; i++) {
              expect(
                progress[i].fraction,
                greaterThanOrEqualTo(progress[i - 1].fraction),
              );
            }
            expect(progress.last.fraction, 1.0);
          },
        );

        test(
          'rejects a page already at or below minPyramidDimension',
          () async {
            final path = _writeSourceFixture(tempDir);
            expect(
              () =>
                  TiffDisplayOptimizer.optimizeLargeSourcePyramidLevelsParallel(
                    _sourcePage(),
                    path,
                    minPyramidDimension: 512,
                    workerCount: 2,
                  ),
              throwsArgumentError,
            );
          },
        );
      });
    });

    test('rejects a non-positive tileSize', () {
      final source = _sourcePage();
      expect(
        () => TiffDisplayOptimizer.optimize(source, tileSize: 0),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive minPyramidDimension', () {
      final source = _sourcePage();
      expect(
        () => TiffDisplayOptimizer.optimize(source, minPyramidDimension: 0),
        throwsArgumentError,
      );
    });
  });
}
