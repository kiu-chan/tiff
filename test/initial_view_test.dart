import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

TiffImageMetadata _metadataFor(int width, int height) => TiffImageMetadata(
  width: width,
  height: height,
  bitsPerSample: const [8, 8, 8],
  samplesPerPixel: 3,
  compression: 1,
  predictor: 1,
  photometric: TiffPhotometric.rgb,
  planarConfiguration: TiffPlanarConfiguration.chunky,
  rowsPerStrip: height,
  stripOffsets: const [0],
  stripByteCounts: const [0],
  tileWidth: null,
  tileLength: null,
  tileOffsets: null,
  tileByteCounts: null,
  colorMap: null,
  geoTiff: null,
  exifTags: null,
  gpsTags: null,
  rawTags: const {},
);

void main() {
  group('TiffInitialView.forViewport', () {
    test('a page smaller than the viewport is shown in full, scaled up', () {
      final metadata = _metadataFor(200, 100);

      final view = TiffInitialView.forViewport(
        metadata,
        viewportWidth: 1000,
        viewportHeight: 1000,
      );

      expect(view.region.x, 0);
      expect(view.region.y, 0);
      expect(view.region.width, 200);
      expect(view.region.height, 100);
      expect(view.zoom, closeTo(5.0, 1e-9)); // 1000 / 200, the tighter fit
    });

    test('a huge page is cropped to a centered region within the pixel '
        'budget instead of decoded whole', () {
      final metadata = _metadataFor(20000, 20000);

      final view = TiffInitialView.forViewport(
        metadata,
        viewportWidth: 1000,
        viewportHeight: 1000,
        maxDecodedPixels: 1000000, // 1000x1000
      );

      expect(view.region.width, 1000);
      expect(view.region.height, 1000);
      // Centered: (20000 - 1000) / 2 == 9500.
      expect(view.region.x, 9500);
      expect(view.region.y, 9500);
      expect(view.zoom, closeTo(1.0, 1e-9));
    });

    test(
      'a budget tighter than the viewport shrinks the region and zooms in '
      'to compensate',
      () {
        final metadata = _metadataFor(20000, 20000);

        final view = TiffInitialView.forViewport(
          metadata,
          viewportWidth: 2000,
          viewportHeight: 2000,
          maxDecodedPixels: 1000000, // 1000x1000 < the 2000x2000 viewport
        );

        expect(view.region.width, 1000);
        expect(view.region.height, 1000);
        expect(view.zoom, closeTo(2.0, 1e-9)); // 2000 / 1000
      },
    );

    test('preserves the viewport aspect ratio when shrinking for budget', () {
      final metadata = _metadataFor(20000, 20000);

      final view = TiffInitialView.forViewport(
        metadata,
        viewportWidth: 2000,
        viewportHeight: 1000,
        maxDecodedPixels: 1000000,
      );

      expect(
        view.region.width / view.region.height,
        closeTo(2.0, 0.01), // matches the viewport's 2:1 aspect ratio
      );
    });

    test('accounts for devicePixelRatio when sizing the region', () {
      final metadata = _metadataFor(20000, 20000);

      final view = TiffInitialView.forViewport(
        metadata,
        viewportWidth: 500,
        viewportHeight: 500,
        devicePixelRatio: 3.0,
        maxDecodedPixels: 100000000,
      );

      expect(view.region.width, 1500);
      expect(view.region.height, 1500);
      expect(view.zoom, closeTo(1.0, 1e-9));
    });

    test('a non-square page keeps the region within bounds on the short '
        'axis', () {
      final metadata = _metadataFor(20000, 400);

      final view = TiffInitialView.forViewport(
        metadata,
        viewportWidth: 1000,
        viewportHeight: 1000,
        maxDecodedPixels: 1000000,
      );

      expect(view.region.height, 400);
      expect(view.region.y, 0);
      expect(view.region.width, lessThanOrEqualTo(20000));
    });

    test('rejects a non-positive viewport size', () {
      final metadata = _metadataFor(1000, 1000);
      expect(
        () => TiffInitialView.forViewport(
          metadata,
          viewportWidth: 0,
          viewportHeight: 100,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive devicePixelRatio', () {
      final metadata = _metadataFor(1000, 1000);
      expect(
        () => TiffInitialView.forViewport(
          metadata,
          viewportWidth: 100,
          viewportHeight: 100,
          devicePixelRatio: 0,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a non-positive decode budget', () {
      final metadata = _metadataFor(1000, 1000);
      expect(
        () => TiffInitialView.forViewport(
          metadata,
          viewportWidth: 100,
          viewportHeight: 100,
          maxDecodedPixels: 0,
        ),
        throwsArgumentError,
      );
    });

    test('the resulting region is always decodable as-is', () {
      final metadata = _metadataFor(9973, 6151); // odd, prime dimensions

      final view = TiffInitialView.forViewport(
        metadata,
        viewportWidth: 812,
        viewportHeight: 1337,
        devicePixelRatio: 2.5,
        maxDecodedPixels: 777777,
      );

      expect(() => view.region.validateWithin(metadata), returnsNormally);
    });
  });
}
