import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

void main() {
  group('ImageResampler.downsampleRgba8', () {
    test('averages a 2x2 block into 1 pixel', () {
      final src = Uint8List.fromList([
        0, 0, 0, 255, 100, 0, 0, 255, //
        0, 100, 0, 255, 0, 0, 100, 255, //
      ]);

      final dst = ImageResampler.downsampleRgba8(src, srcWidth: 2, srcHeight: 2, dstWidth: 1, dstHeight: 1);

      expect(dst, [25, 25, 25, 255]);
    });

    test('halves a 4x4 image into a 2x2 image, block-averaged', () {
      // Each 2x2 source block is a uniform color, so downsampling should
      // reproduce that color exactly in the corresponding output pixel.
      final blocks = [
        [10, 20, 30, 255],
        [40, 50, 60, 255],
        [70, 80, 90, 255],
        [100, 110, 120, 255],
      ];
      final src = Uint8List(4 * 4 * 4);
      for (var by = 0; by < 2; by++) {
        for (var bx = 0; bx < 2; bx++) {
          final color = blocks[by * 2 + bx];
          for (var y = 0; y < 2; y++) {
            for (var x = 0; x < 2; x++) {
              final px = bx * 2 + x;
              final py = by * 2 + y;
              final o = (py * 4 + px) * 4;
              src.setRange(o, o + 4, color);
            }
          }
        }
      }

      final dst = ImageResampler.downsampleRgba8(src, srcWidth: 4, srcHeight: 4, dstWidth: 2, dstHeight: 2);

      expect(dst, [
        10, 20, 30, 255, //
        40, 50, 60, 255, //
        70, 80, 90, 255, //
        100, 110, 120, 255, //
      ]);
    });

    test('returns the input unchanged when dst size equals src size', () {
      final src = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final dst = ImageResampler.downsampleRgba8(src, srcWidth: 2, srcHeight: 1, dstWidth: 2, dstHeight: 1);
      expect(dst, same(src));
    });

    test('covers every source pixel exactly once across a non-integer ratio', () {
      // 5x1 -> 2x1: spans of 2/3 pixels, exercising the rounding guard in
      // _spanEnd rather than a clean power-of-two halving.
      final src = Uint8List.fromList([
        10, 0, 0, 0, 20, 0, 0, 0, 30, 0, 0, 0, 40, 0, 0, 0, 50, 0, 0, 0, //
      ]);
      final dst = ImageResampler.downsampleRgba8(src, srcWidth: 5, srcHeight: 1, dstWidth: 2, dstHeight: 1);

      // First output pixel covers source x in [0, 2) -> avg(10, 20) = 15;
      // second covers x in [2, 5) -> avg(30, 40, 50) = 40.
      expect(dst[0], 15);
      expect(dst[4], 40);
    });

    test('rejects an upsample request', () {
      final src = Uint8List(2 * 2 * 4);
      expect(
        () => ImageResampler.downsampleRgba8(src, srcWidth: 2, srcHeight: 2, dstWidth: 4, dstHeight: 4),
        throwsArgumentError,
      );
    });

    test('rejects a source buffer of the wrong length', () {
      final src = Uint8List(3 * 4); // too short for 2x2
      expect(
        () => ImageResampler.downsampleRgba8(src, srcWidth: 2, srcHeight: 2, dstWidth: 1, dstHeight: 1),
        throwsA(isA<TiffException>()),
      );
    });
  });
}
