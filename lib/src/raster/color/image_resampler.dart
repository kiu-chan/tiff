import 'dart:typed_data';

import '../../tiff_exception.dart';

/// Downsampling for already-decoded 8-bit RGBA pixel data (e.g. the output
/// of [TiffImage.decodeRgba8]) — the building block a pyramid of
/// progressively smaller pages is built from (see `TiffDisplayOptimizer`).
class ImageResampler {
  const ImageResampler._();

  /// Downsamples interleaved 8-bit RGBA data from `srcWidth x srcHeight` to
  /// `dstWidth x dstHeight` (both must be `<=` the source dimensions) using
  /// box filtering: each output pixel is the average (each channel
  /// independently, alpha included) of every source pixel that falls
  /// within the source rectangle it stands in for. This is the same
  /// technique `mipmap`/pyramid generators generally use — it stays sharp
  /// under fairly large downsample ratios, unlike a nearest-neighbor or
  /// naive point-sample reduction, which can alias or skip detail entirely
  /// between sampled pixels.
  static Uint8List downsampleRgba8(
    Uint8List rgba, {
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
  }) {
    if (srcWidth <= 0 || srcHeight <= 0) {
      throw ArgumentError('srcWidth and srcHeight must be > 0');
    }
    if (dstWidth <= 0 || dstHeight <= 0) {
      throw ArgumentError('dstWidth and dstHeight must be > 0');
    }
    if (dstWidth > srcWidth || dstHeight > srcHeight) {
      throw ArgumentError(
        'downsampleRgba8 only shrinks an image — requested '
        '${dstWidth}x$dstHeight from a ${srcWidth}x$srcHeight source',
      );
    }
    if (rgba.length != srcWidth * srcHeight * 4) {
      throw TiffException(
        'rgba has ${rgba.length} bytes, expected ${srcWidth * srcHeight * 4} '
        '(srcWidth * srcHeight * 4)',
      );
    }
    if (dstWidth == srcWidth && dstHeight == srcHeight) {
      return rgba;
    }

    final dst = Uint8List(dstWidth * dstHeight * 4);
    for (var oy = 0; oy < dstHeight; oy++) {
      final sy0 = (oy * srcHeight) ~/ dstHeight;
      final sy1 = _spanEnd(oy, dstHeight, srcHeight, sy0);
      for (var ox = 0; ox < dstWidth; ox++) {
        final sx0 = (ox * srcWidth) ~/ dstWidth;
        final sx1 = _spanEnd(ox, dstWidth, srcWidth, sx0);

        var r = 0, g = 0, b = 0, a = 0, count = 0;
        for (var sy = sy0; sy < sy1; sy++) {
          var i = (sy * srcWidth + sx0) * 4;
          for (var sx = sx0; sx < sx1; sx++) {
            r += rgba[i];
            g += rgba[i + 1];
            b += rgba[i + 2];
            a += rgba[i + 3];
            count++;
            i += 4;
          }
        }

        final o = (oy * dstWidth + ox) * 4;
        dst[o] = (r / count).round();
        dst[o + 1] = (g / count).round();
        dst[o + 2] = (b / count).round();
        dst[o + 3] = (a / count).round();
      }
    }
    return dst;
  }

  /// The exclusive end of the source span output pixel [out] (out of
  /// [dstExtent] total) covers along one axis of [srcExtent] — at least one
  /// source pixel wide, and never past [srcExtent], so integer-division
  /// rounding can't leave a span (or the whole source, on its last output
  /// pixel) uncovered.
  static int _spanEnd(int out, int dstExtent, int srcExtent, int start) {
    final end = ((out + 1) * srcExtent) ~/ dstExtent;
    return (out == dstExtent - 1 ? srcExtent : end).clamp(start + 1, srcExtent);
  }
}
