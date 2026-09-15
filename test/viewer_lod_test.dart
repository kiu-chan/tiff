import 'dart:typed_data';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:tiff/src/viewer/lod_worker.dart';
import 'package:tiff/src/viewer/pyramid_source.dart';
import 'package:tiff/src/viewer/viewport_math.dart';
import 'package:tiff/tiff.dart';

TiffImageSpec _spec(int width, int height, {int? tile, int? rowsPerStrip}) =>
    TiffImageSpec(
      width: width,
      height: height,
      samplesPerPixel: 3,
      bitsPerSample: 8,
      photometric: TiffPhotometric.rgb,
      samples: Uint8List(width * height * 3),
      tileWidth: tile,
      tileLength: tile,
      rowsPerStrip: rowsPerStrip,
    );

List<TiffImage> _pages(List<TiffImageSpec> specs) =>
    TiffDecoder.decode(TiffEncoder.encode(specs)).images;

LodWorkerRequest _request({
  required int width,
  required int height,
  required int memberWidth,
  required int memberHeight,
  int reduction = 0,
}) => (
  id: 0,
  rung: 0,
  x: 0,
  y: 0,
  width: width,
  height: height,
  memberWidth: memberWidth,
  memberHeight: memberHeight,
  reduction: reduction,
  brightness: 0,
  contrast: 1,
  gamma: 1,
);

void main() {
  group('viewport math', () {
    test(
      'selectSpan merges tiles until they reach the minimum screen size',
      () {
        expect(selectSpan(256), 0);
        expect(selectSpan(64), 0);
        expect(selectSpan(10), 3); // 10 * 8 = 80 >= 64, 10 * 4 = 40 < 64
        expect(selectSpan(0.001, maxSpan: 4), 4);
      },
    );

    test(
      'selectReduction shrinks only while pixels stay within maxUpsample',
      () {
        expect(selectReduction(1.0, maxUpsample: 1.3), 0);
        expect(selectReduction(0.3, maxUpsample: 1.3), 2); // 0.3 * 4 = 1.2
        expect(selectReduction(0.01, maxUpsample: 1.3), 3);
        expect(selectReduction(0.01, maxUpsample: 1.3, maxReduction: 5), 5);
      },
    );

    test('reducedExtent rounds up', () {
      expect(reducedExtent(512, 1), 256);
      expect(reducedExtent(513, 1), 257);
      expect(reducedExtent(5, 3), 1);
    });

    test('LodGrid.visible clamps to the grid and is null off the image', () {
      const level = LodLevel(
        width: 1000,
        height: 1000,
        tileWidth: 256,
        tileHeight: 256,
        downsampleX: 1,
        downsampleY: 1,
      );
      final range = const LodGrid(
        level,
        0,
      ).visible(const Size(100, 100), 1, const Offset(300, 300))!;
      expect(
        [range.minTx, range.maxTx, range.minTy, range.maxTy],
        [1, 1, 1, 1],
      );

      final withMargin = const LodGrid(
        level,
        0,
      ).visible(const Size(100, 100), 1, const Offset(300, 300), margin: 5)!;
      expect(
        [
          withMargin.minTx,
          withMargin.maxTx,
          withMargin.minTy,
          withMargin.maxTy,
        ],
        [0, 3, 0, 3],
      );

      expect(
        const LodGrid(
          level,
          0,
        ).visible(const Size(100, 100), 1, const Offset(-500, -500)),
        isNull,
      );

      // A span-1 composite covers 512 base pixels.
      final composite = const LodGrid(
        level,
        1,
      ).visible(const Size(100, 100), 1, const Offset(600, 0))!;
      expect([composite.minTx, composite.maxTx], [1, 1]);
    });

    test('tilesNearestFirst starts at the center and honors limit/exclude', () {
      const range = TileRange(minTx: 0, maxTx: 4, minTy: 0, maxTy: 4);
      expect(tilesNearestFirst(range, 2.5, 2.5, 1), [(2, 2)]);

      final ring = tilesNearestFirst(range, 2.5, 2.5, 9);
      expect(ring.toSet(), {
        for (var x = 1; x <= 3; x++)
          for (var y = 1; y <= 3; y++) (x, y),
      });

      const core = TileRange(minTx: 1, maxTx: 3, minTy: 1, maxTy: 3);
      final rest = tilesNearestFirst(range, 2.5, 2.5, 100, exclude: core);
      expect(rest, hasLength(25 - 9));
      expect(rest.any((t) => core.contains(t.$1, t.$2)), isFalse);
    });
  });

  group('pyramid source', () {
    test('findPyramidRungs keeps smaller same-aspect pages, largest first', () {
      final pages = _pages([
        _spec(800, 400),
        _spec(100, 100), // label-like: wrong aspect
        _spec(200, 100),
        _spec(400, 200),
        _spec(400, 200), // duplicate width
      ]);
      final rungs = findPyramidRungs(pages);
      expect([for (final r in rungs) r.metadata.width], [800, 400, 200]);
      expect(identical(rungs.first, pages.first), isTrue);
    });

    test('findPyramidRungs folds in extra pages from a sidecar', () {
      final pages = _pages([_spec(800, 400)]);
      final extra = _pages([_spec(400, 200), _spec(200, 100)]);
      final rungs = findPyramidRungs(pages, extraPages: extra);
      expect([for (final r in rungs) r.metadata.width], [800, 400, 200]);
    });

    test('lodLevelFor uses tiles for tiled pages and bands for strips', () {
      final pages = _pages([
        _spec(1000, 500, tile: 128),
        _spec(500, 250, rowsPerStrip: 10),
      ]);
      final tiled = lodLevelFor(pages[0].metadata, pages[0].metadata);
      expect(
        [tiled.tileWidth, tiled.tileHeight, tiled.stripBands],
        [128, 128, false],
      );

      final strips = lodLevelFor(pages[1].metadata, pages[0].metadata);
      expect(strips.stripBands, isTrue);
      expect(strips.tileWidth, 500);
      expect(strips.downsampleX, 2);
      expect(strips.downsampleY, 2);
    });

    test('stripBandRows groups whole strips and caps band height', () {
      final aligned = _pages([
        _spec(1000, 5000, rowsPerStrip: 10),
      ]).single.metadata;
      final rows = stripBandRows(aligned);
      expect(rows % 10, 0, reason: 'bands must not cut a strip in two');
      expect(rows, lessThanOrEqualTo(maxTileExtent));
      expect(rows * 1000 * 7, lessThanOrEqualTo(maxStripBandBytes));

      final tall = _pages([_spec(4, 8000, rowsPerStrip: 8000)]).single.metadata;
      expect(stripBandRows(tall), maxTileExtent);
    });

    test('planOverview picks the smallest rung at least maxDimension long', () {
      final rungs = [
        for (final page in _pages([
          _spec(800, 400),
          _spec(400, 200),
          _spec(200, 100),
        ]))
          page.metadata,
      ];
      final shrunk = planOverview(rungs, maxDimension: 300);
      expect(shrunk, (rung: 1, width: 300, height: 150, sparse: false));

      final whole = planOverview(rungs, maxDimension: 1000);
      expect(whole, (rung: 0, width: 800, height: 400, sparse: false));
    });

    test('rungDownsample sees through rungs padded to whole tiles', () {
      final pages = _pages([
        _spec(1024, 784, tile: 16),
        _spec(128, 112, tile: 16), // 8x: 98 rows of image + 14 of padding
        _spec(64, 64, tile: 16), // 16x: 49 rows of image + 15 of padding
        _spec(99, 50, rowsPerStrip: 50), // label
        _spec(512, 392), // plain halving, strips
      ]);
      final base = pages[0].metadata;
      expect(rungDownsample(pages[1].metadata, base), (8.0, 8.0));
      expect(rungDownsample(pages[2].metadata, base), (16.0, 16.0));
      expect(rungDownsample(pages[3].metadata, base), isNull);
      expect(rungDownsample(pages[4].metadata, base), (2.0, 2.0));
      expect(
        [for (final r in findPyramidRungs(pages)) r.metadata.width],
        [1024, 512, 128, 64],
      );
    });

    test('describeRungs adds an overview level only for shallow pyramids', () {
      final deep = describeRungs([
        for (final page in _pages([_spec(8192, 64), _spec(2048, 16)]))
          page.metadata,
      ]);
      expect([for (final l in deep.levels) l.rung], [0, 1]);
      expect(deep.overview.width, previewMaxDimension);

      final shallow = describeRungs([
        for (final page in _pages([_spec(16384, 64, tile: 256)]))
          page.metadata,
      ]);
      expect([for (final l in shallow.levels) l.rung], [0, overviewRung]);
      expect(shallow.overviewLevel.width, overviewMaxDimension);
      expect(shallow.overviewLevel.downsampleX, 4);
    });
  });

  group('assembleRegion', () {
    test('returns a single unreduced member as-is', () {
      final member = Uint8List.fromList(List.generate(16, (i) => i));
      final (rgba, width, height) = assembleRegion(
        _request(width: 2, height: 2, memberWidth: 2, memberHeight: 2),
        (x, y, w, h) => member,
      );
      expect(identical(rgba, member), isTrue);
      expect((width, height), (2, 2));
    });

    test(
      'box-filters across members and leaves failed members transparent',
      () {
        final loaded = <(int, int, int, int)>[];
        final (rgba, width, height) = assembleRegion(
          _request(
            width: 4,
            height: 2,
            memberWidth: 2,
            memberHeight: 2,
            reduction: 1,
          ),
          (x, y, w, h) {
            loaded.add((x, y, w, h));
            if (x == 2) throw StateError('unreadable tile');
            // Red 10, 20, 30, 40 across the member's four pixels.
            return Uint8List.fromList([
              10, 0, 0, 255, 20, 0, 0, 255, //
              30, 0, 0, 255, 40, 0, 0, 255,
            ]);
          },
        );
        expect(loaded, [(0, 0, 2, 2), (2, 0, 2, 2)]);
        expect((width, height), (2, 1));
        expect(rgba.sublist(0, 4), [25, 0, 0, 255]);
        expect(rgba.sublist(4, 8), [0, 0, 0, 0]);
      },
    );

    test('a composite of row-wide strip members reads each row once', () {
      final loaded = <(int, int, int, int)>[];
      assembleRegion(
        _request(width: 8, height: 6, memberWidth: 8, memberHeight: 2),
        (x, y, w, h) {
          loaded.add((x, y, w, h));
          return Uint8List(w * h * 4);
        },
      );
      expect(loaded, [(0, 0, 8, 2), (0, 2, 8, 2), (0, 4, 8, 2)]);
    });
  });
}
