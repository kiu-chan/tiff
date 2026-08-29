import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/src/optimize/banded_downsampler.dart';

/// A source page with a distinct, position-derived value per pixel/channel
/// — chosen so any row/column mixup in the banding logic shows up as a
/// wrong value rather than accidentally passing.
TiffImage _sourcePage(int width, int height) {
  final samples = <int>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      samples.addAll([(x * 3) % 256, (y * 5) % 256, (x + y) % 256]);
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
      final banded = BandedDownsampler.downsample(page, dstWidth: 16, dstHeight: 16);
      expect(banded, whole);
    });

    test('matches ImageResampler.downsampleRgba8 for a non-power-of-two ratio', () {
      final page = _sourcePage(30, 21);
      final whole = ImageResampler.downsampleRgba8(
        page.decodeRgba8(),
        srcWidth: 30,
        srcHeight: 21,
        dstWidth: 7,
        dstHeight: 5,
      );
      final banded = BandedDownsampler.downsample(page, dstWidth: 7, dstHeight: 5);
      expect(banded, whole);
    });

    test('a tiny maxBandBytes (many small bands) still matches the whole-buffer result', () {
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
      final banded = BandedDownsampler.downsample(page, dstWidth: 9, dstHeight: 9, maxBandBytes: 160);
      expect(banded, whole);
    });

    test('dst == src size returns the source pixels unchanged', () {
      final page = _sourcePage(8, 8);
      final banded = BandedDownsampler.downsample(page, dstWidth: 8, dstHeight: 8);
      expect(banded, page.decodeRgba8());
    });

    test('rejects a dst larger than the source', () {
      final page = _sourcePage(8, 8);
      expect(() => BandedDownsampler.downsample(page, dstWidth: 16, dstHeight: 8), throwsArgumentError);
    });

    test('rejects a non-positive maxBandBytes', () {
      final page = _sourcePage(8, 8);
      expect(() => BandedDownsampler.downsample(page, dstWidth: 4, dstHeight: 4, maxBandBytes: 0), throwsArgumentError);
    });
  });
}
