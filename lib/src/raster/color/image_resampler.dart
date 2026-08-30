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

    // The pyramid this feeds (see `TiffDisplayOptimizer`) halves exactly at
    // every rung after the first, so this exact-2x case is by far the most
    // common call shape in practice — worth a dedicated tight loop with a
    // fixed 2x2 span (no per-pixel span-size lookup, no variable-length
    // inner loop) rather than falling through the general path below, which
    // recomputes each span's bounds and re-derives `count` for every single
    // output pixel even though it's the same 4 here every time.
    if (srcWidth == dstWidth * 2 && srcHeight == dstHeight * 2) {
      final srcRowStride = srcWidth * 4;
      for (var oy = 0; oy < dstHeight; oy++) {
        final rowA = (oy * 2) * srcRowStride;
        final rowB = rowA + srcRowStride;
        var o = oy * dstWidth * 4;
        var iA = rowA;
        var iB = rowB;
        for (var ox = 0; ox < dstWidth; ox++) {
          dst[o] = (rgba[iA] + rgba[iA + 4] + rgba[iB] + rgba[iB + 4] + 2) >> 2;
          dst[o + 1] = (rgba[iA + 1] + rgba[iA + 5] + rgba[iB + 1] + rgba[iB + 5] + 2) >> 2;
          dst[o + 2] = (rgba[iA + 2] + rgba[iA + 6] + rgba[iB + 2] + rgba[iB + 6] + 2) >> 2;
          dst[o + 3] = (rgba[iA + 3] + rgba[iA + 7] + rgba[iB + 3] + rgba[iB + 7] + 2) >> 2;
          o += 4;
          iA += 8;
          iB += 8;
        }
      }
      return dst;
    }

    // Precomputed once — every output row covers the same source column
    // spans, only its row span changes, so recomputing sx0/sx1 inside the
    // oy loop (once per output row) would redo the same division dstHeight
    // times over for no reason.
    final sx0 = List<int>.generate(dstWidth, (ox) => (ox * srcWidth) ~/ dstWidth);
    final sx1 = List<int>.generate(dstWidth, (ox) => _spanEnd(ox, dstWidth, srcWidth, sx0[ox]));

    for (var oy = 0; oy < dstHeight; oy++) {
      final sy0 = (oy * srcHeight) ~/ dstHeight;
      final sy1 = _spanEnd(oy, dstHeight, srcHeight, sy0);
      for (var ox = 0; ox < dstWidth; ox++) {
        var r = 0, g = 0, b = 0, a = 0, count = 0;
        for (var sy = sy0; sy < sy1; sy++) {
          var i = (sy * srcWidth + sx0[ox]) * 4;
          for (var sx = sx0[ox]; sx < sx1[ox]; sx++) {
            r += rgba[i];
            g += rgba[i + 1];
            b += rgba[i + 2];
            a += rgba[i + 3];
            count++;
            i += 4;
          }
        }

        // Integer round-half-up instead of a double divide-and-round — see
        // the 2x fast path above for the same identity in its unrolled form.
        final o = (oy * dstWidth + ox) * 4;
        final count2 = count * 2;
        dst[o] = (2 * r + count) ~/ count2;
        dst[o + 1] = (2 * g + count) ~/ count2;
        dst[o + 2] = (2 * b + count) ~/ count2;
        dst[o + 3] = (2 * a + count) ~/ count2;
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
