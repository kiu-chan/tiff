import 'dart:math' as math;
import 'dart:typed_data';

import '../image/photometric.dart';
import '../image/tiff_image.dart';
import '../raster/color/image_resampler.dart';
import '../tiff_encoder.dart';
import '../write/tiff_image_spec.dart';

/// How [TiffDisplayOptimizer.optimize] restructures a page.
enum TiffOptimizationMode {
  /// Re-tile the page at its native resolution only — no smaller rungs.
  /// Fixes arbitrary-region decode being inefficient on a strip-organized
  /// source (a strip can't be partially decoded, so cropping a small
  /// region out of a wide strip means decompressing the whole strip anyway)
  /// without the extra time/space cost of building a pyramid.
  tiledOnly,

  /// Re-tile the page, then append progressively half-sized, tiled rungs
  /// down to [TiffDisplayOptimizer.optimize]'s `minPyramidDimension` — the
  /// same structure many whole-slide-image scanners already produce, and
  /// that [TiffDisplayOptimizer]'s own README-documented viewer pattern
  /// (pick the smallest sufficient rung, decode by tile) is built around.
  /// Costs more time and disk to build than [tiledOnly], but means a
  /// zoomed-out view never has to downsample the full-resolution page on
  /// the fly.
  tiledPyramid,
}

/// Rewrites a page into a structure suited to smooth interactive display
/// later — tiled (and optionally pyramided), rather than the strip layout
/// and single resolution a source TIFF may only have.
///
/// This is meant to run as a deliberate, one-off "prepare this file" step
/// *before* a viewer opens it — not during interactive display, and not
/// merged into the read path. [optimize] decodes the whole page into memory
/// as RGBA8 (via [TiffImage.decodeRgba8]) to do the rewrite, so check
/// `metadata.width * metadata.height` against your own memory budget first
/// for a very large page; there's no streaming/bounded-memory path here the
/// way [TiffImage.decodeRegion] gives the read side.
///
/// The output is always plain 8-bit RGB (alpha, if the source had any, is
/// dropped) — appropriate for a display copy, not an archival one; keep the
/// original file if you need its original bit depth, palette, or alpha.
class TiffDisplayOptimizer {
  const TiffDisplayOptimizer._();

  /// Returns [page] rewritten per [mode] (see [TiffOptimizationMode]) as a
  /// new, encoded TIFF.
  ///
  /// - [tileSize]: tile width/height in pixels for every rung. A tile
  ///   larger than a rung's own dimensions is fine — [TiffEncoder] pads
  ///   edge tiles on write.
  /// - [minPyramidDimension]: with [TiffOptimizationMode.tiledPyramid],
  ///   rungs keep halving until the longest side is at or below this; the
  ///   smallest rung is always kept even if that overshoots it. Ignored
  ///   with [TiffOptimizationMode.tiledOnly].
  /// - [compression]: a [TiffImageSpec.compression] tag value; the default
  ///   (8, Deflate/ZIP) is lossless and needs no extra setup. This package
  ///   can't write JPEG (see the README's Limitations), the usual choice
  ///   for a smaller display copy — pick a lossy path yourself first (e.g.
  ///   via `package:tiff/tiff_image_adapter.dart`) if that trade-off is
  ///   worth it for your use case.
  static Uint8List optimize(
    TiffImage page, {
    TiffOptimizationMode mode = TiffOptimizationMode.tiledPyramid,
    int tileSize = 512,
    int minPyramidDimension = 512,
    int compression = 8,
  }) {
    if (tileSize <= 0) {
      throw ArgumentError('tileSize must be > 0');
    }
    if (minPyramidDimension <= 0) {
      throw ArgumentError('minPyramidDimension must be > 0');
    }

    var width = page.metadata.width;
    var height = page.metadata.height;
    var rgba = page.decodeRgba8();

    final specs = <TiffImageSpec>[_tiledRgbSpec(rgba, width, height, tileSize, compression)];

    if (mode == TiffOptimizationMode.tiledPyramid) {
      while (math.max(width, height) > minPyramidDimension) {
        final nextWidth = math.max(1, width ~/ 2);
        final nextHeight = math.max(1, height ~/ 2);
        rgba = ImageResampler.downsampleRgba8(
          rgba,
          srcWidth: width,
          srcHeight: height,
          dstWidth: nextWidth,
          dstHeight: nextHeight,
        );
        width = nextWidth;
        height = nextHeight;
        specs.add(_tiledRgbSpec(rgba, width, height, tileSize, compression));
      }
    }

    return TiffEncoder.encode(specs);
  }

  static TiffImageSpec _tiledRgbSpec(Uint8List rgba, int width, int height, int tileSize, int compression) {
    return TiffImageSpec(
      width: width,
      height: height,
      samplesPerPixel: 3,
      bitsPerSample: 8,
      photometric: TiffPhotometric.rgb,
      samples: _dropAlpha(rgba),
      compression: compression,
      tileWidth: tileSize,
      tileLength: tileSize,
    );
  }

  static Uint8List _dropAlpha(Uint8List rgba) {
    final rgb = Uint8List(rgba.length ~/ 4 * 3);
    var o = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      rgb[o++] = rgba[i];
      rgb[o++] = rgba[i + 1];
      rgb[o++] = rgba[i + 2];
    }
    return rgb;
  }
}
