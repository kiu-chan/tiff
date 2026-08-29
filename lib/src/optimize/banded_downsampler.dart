import 'dart:math' as math;
import 'dart:typed_data';

import '../image/tiff_image.dart';
import '../region/tiff_region.dart';
import '../tiff_exception.dart';

/// Downsamples a [TiffImage] directly from its native resolution to a much
/// smaller `dstWidth x dstHeight`, decoding the source in row bands rather
/// than as one whole [TiffImage.decodeRgba8] call — bounded memory
/// regardless of how large the source page is, unlike
/// [ImageResampler.downsampleRgba8] (which needs the whole source already
/// decoded).
///
/// Produces exactly the same box-average result
/// [ImageResampler.downsampleRgba8] would if it *could* be handed the whole
/// decoded source: every output pixel averages precisely the same source
/// pixel span (same `_spanEnd` formula, applied per axis) — banding only
/// changes how that span's pixels get read off disk, never which pixels
/// contribute or how they're weighted.
class BandedDownsampler {
  const BandedDownsampler._();

  /// [maxBandBytes] bounds one row-band's decoded size (`bandRows *
  /// srcWidth * 4`) — the only memory this holds proportional to the
  /// source; everything else here is proportional to `dstWidth * dstHeight`
  /// (the caller's own choice, already assumed small by the time this is
  /// called).
  static Uint8List downsample(
    TiffImage page, {
    required int dstWidth,
    required int dstHeight,
    int maxBandBytes = 128 * 1024 * 1024,
  }) {
    final metadata = page.metadata;
    final srcWidth = metadata.width;
    final srcHeight = metadata.height;

    if (dstWidth <= 0 || dstHeight <= 0) {
      throw ArgumentError('dstWidth and dstHeight must be > 0');
    }
    if (dstWidth > srcWidth || dstHeight > srcHeight) {
      throw ArgumentError(
        'downsample only shrinks an image — requested ${dstWidth}x$dstHeight '
        'from a ${srcWidth}x$srcHeight source',
      );
    }
    if (maxBandBytes <= 0) {
      throw ArgumentError('maxBandBytes must be > 0');
    }

    final dst = Uint8List(dstWidth * dstHeight * 4);
    if (dstWidth == srcWidth && dstHeight == srcHeight) {
      final rgba = page.decodeRegionRgba8(TiffRegion(x: 0, y: 0, width: srcWidth, height: srcHeight));
      dst.setAll(0, rgba);
      return dst;
    }

    final bytesPerSrcRow = srcWidth * 4;
    final maxRowsPerBand = math.max(1, maxBandBytes ~/ bytesPerSrcRow);

    // Precomputed once — every output row's source column span never
    // changes band to band, only its row span does.
    final sx0 = List<int>.generate(dstWidth, (ox) => _spanStart(ox, dstWidth, srcWidth));
    final sx1 = List<int>.generate(dstWidth, (ox) => _spanEnd(ox, dstWidth, srcWidth, sx0[ox]));

    var oy = 0;
    while (oy < dstHeight) {
      final bandSyStart = _spanStart(oy, dstHeight, srcHeight);
      var oyEnd = oy;
      var bandSyEnd = bandSyStart;
      // Grows the output-row group as long as the source span it would
      // need stays within maxRowsPerBand — always includes at least one
      // output row, even if that alone exceeds the budget (an
      // unreasonably tight budget or huge downsample ratio shouldn't make
      // this loop fail to progress).
      while (oyEnd < dstHeight) {
        final candidateEnd = _spanEnd(oyEnd, dstHeight, srcHeight, _spanStart(oyEnd, dstHeight, srcHeight));
        if (oyEnd > oy && candidateEnd - bandSyStart > maxRowsPerBand) break;
        bandSyEnd = candidateEnd;
        oyEnd++;
      }

      final band = page.decodeRegionRgba8(
        TiffRegion(x: 0, y: bandSyStart, width: srcWidth, height: bandSyEnd - bandSyStart),
      );
      if (band.length != (bandSyEnd - bandSyStart) * srcWidth * 4) {
        throw TiffException('decodeRegionRgba8 returned an unexpected byte count for a banded downsample');
      }

      for (var y = oy; y < oyEnd; y++) {
        final ySpanStart = _spanStart(y, dstHeight, srcHeight);
        final sy0 = ySpanStart - bandSyStart;
        final sy1 = _spanEnd(y, dstHeight, srcHeight, ySpanStart) - bandSyStart;
        for (var ox = 0; ox < dstWidth; ox++) {
          var r = 0, g = 0, b = 0, a = 0, count = 0;
          for (var sy = sy0; sy < sy1; sy++) {
            var i = (sy * srcWidth + sx0[ox]) * 4;
            for (var sx = sx0[ox]; sx < sx1[ox]; sx++) {
              r += band[i];
              g += band[i + 1];
              b += band[i + 2];
              a += band[i + 3];
              count++;
              i += 4;
            }
          }
          final o = (y * dstWidth + ox) * 4;
          dst[o] = (r / count).round();
          dst[o + 1] = (g / count).round();
          dst[o + 2] = (b / count).round();
          dst[o + 3] = (a / count).round();
        }
      }
      oy = oyEnd;
    }
    return dst;
  }

  /// The inclusive start of the source span output pixel [out] (out of
  /// [dstExtent] total) covers along one axis of [srcExtent].
  static int _spanStart(int out, int dstExtent, int srcExtent) => (out * srcExtent) ~/ dstExtent;

  /// The exclusive end of that same span — identical formula to
  /// [ImageResampler.downsampleRgba8]'s own `_spanEnd`, kept in lockstep so
  /// this produces the same output a whole-buffer call would.
  static int _spanEnd(int out, int dstExtent, int srcExtent, int start) {
    final end = ((out + 1) * srcExtent) ~/ dstExtent;
    return (out == dstExtent - 1 ? srcExtent : end).clamp(start + 1, srcExtent);
  }
}
