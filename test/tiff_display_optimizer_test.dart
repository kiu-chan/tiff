import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

/// Builds a small strip-organized (non-tiled) source page — an 8x8 RGB
/// gradient — the kind of plain source [TiffDisplayOptimizer] is meant to
/// restructure.
TiffImage _sourcePage({int width = 8, int height = 8}) {
  final samples = <int>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      samples.addAll([(x * 255 ~/ width), (y * 255 ~/ height), 128]);
    }
  }
  final spec = TiffImageSpec(
    width: width,
    height: height,
    samplesPerPixel: 3,
    bitsPerSample: 8,
    photometric: TiffPhotometric.rgb,
    samples: samples,
  );
  final bytes = TiffEncoder.encode([spec]);
  return TiffDecoder.decode(bytes).images.single;
}

void main() {
  group('TiffDisplayOptimizer.optimize', () {
    test('tiledOnly re-tiles at native resolution with no extra pages', () {
      final source = _sourcePage(width: 8, height: 8);
      expect(source.metadata.isTiled, isFalse);

      final optimized = TiffDecoder.decode(
        TiffDisplayOptimizer.optimize(source, mode: TiffOptimizationMode.tiledOnly, tileSize: 4),
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
        TiffDisplayOptimizer.optimize(source, mode: TiffOptimizationMode.tiledOnly, tileSize: 4),
      );
      final optimizedRgba = optimized.images.single.decodeRgba8();

      for (var i = 0; i < sourceRgba.length; i += 4) {
        expect(optimizedRgba[i], sourceRgba[i], reason: 'R at pixel ${i ~/ 4}');
        expect(optimizedRgba[i + 1], sourceRgba[i + 1], reason: 'G at pixel ${i ~/ 4}');
        expect(optimizedRgba[i + 2], sourceRgba[i + 2], reason: 'B at pixel ${i ~/ 4}');
      }
    });

    test('tiledPyramid appends progressively halved, tiled rungs down to minPyramidDimension', () {
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
      final dims = optimized.images.map((i) => (i.metadata.width, i.metadata.height)).toList();
      expect(dims, [(32, 32), (16, 16), (8, 8)]);
      for (final image in optimized.images) {
        expect(image.metadata.isTiled, isTrue);
      }
    });

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

      final dims = optimized.images.map((i) => (i.metadata.width, i.metadata.height)).toList();
      expect(dims, [(32, 8), (16, 4), (8, 2)]);
    });

    test('a page already at or below minPyramidDimension yields a single rung', () {
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
    });

    test('a tile larger than the page is padded, not rejected', () {
      final source = _sourcePage(width: 8, height: 8);
      final optimized = TiffDecoder.decode(
        TiffDisplayOptimizer.optimize(source, mode: TiffOptimizationMode.tiledOnly, tileSize: 64),
      );
      final page = optimized.images.single;
      expect(page.metadata.width, 8);
      expect(page.metadata.height, 8);
      // Decoding should still return exactly the page's own dimensions,
      // not the (padded) tile size.
      expect(page.decodeRgba8().length, 8 * 8 * 4);
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
