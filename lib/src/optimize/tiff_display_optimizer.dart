import 'dart:math' as math;
import 'dart:typed_data';

import '../image/photometric.dart';
import '../image/tiff_image.dart';
import '../raster/color/image_resampler.dart';
import '../tiff_encoder.dart';
import '../write/tiff_image_spec.dart';
import 'banded_downsampler.dart';

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

  /// Builds the same progressively half-sized, tiled rungs as
  /// [tiledPyramid], but *without* re-encoding the base resolution itself
  /// — the result holds only the smaller rungs, meant to sit as a sidecar
  /// next to a source that already serves the base resolution well enough
  /// on its own (e.g. it's already tiled), rather than as a full
  /// standalone replacement for it. This is what makes the output cheap
  /// to treat as a disposable cache: typically a small fraction of the
  /// source's own size, since the (by far largest) base-resolution copy
  /// [tiledPyramid] would otherwise duplicate is never written.
  /// [optimize] still decodes the source's full resolution into memory to
  /// derive these rungs from — there's no way to downsample without it —
  /// this only changes what gets *encoded*.
  /// Throws [ArgumentError] if the page's longest side is already at or
  /// below `minPyramidDimension`, since there would be no smaller rung to
  /// build.
  pyramidLevelsOnly,
}

/// Progress reported by [TiffDisplayOptimizer.optimize] as it works:
/// [completedSteps] out of [totalSteps] "steps" done so far — one step per
/// pyramid rung built, plus one for the final encode — and the same
/// expressed as [fraction] (`completedSteps / totalSteps`) for a caller
/// that just wants a single number to drive a progress bar.
typedef TiffOptimizeProgress = ({int completedSteps, int totalSteps, double fraction});

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
  /// - [minPyramidDimension]: with [TiffOptimizationMode.tiledPyramid] or
  ///   [TiffOptimizationMode.pyramidLevelsOnly], rungs keep halving until
  ///   the longest side is at or below this; the smallest rung is always
  ///   kept even if that overshoots it. Ignored with
  ///   [TiffOptimizationMode.tiledOnly].
  /// - [compression]: a [TiffImageSpec.compression] tag value; the default
  ///   (8, Deflate/ZIP) is lossless and needs no extra setup. This package
  ///   can't write JPEG (see the README's Limitations), the usual choice
  ///   for a smaller display copy — pick a lossy path yourself first (e.g.
  ///   via `package:tiff/tiff_image_adapter.dart`) if that trade-off is
  ///   worth it for your use case.
  /// - [onProgress]: called with a [TiffOptimizeProgress] as work completes
  ///   — once after the initial decode (and its base-resolution rung), once
  ///   more per additional pyramid rung, then a final call once the whole
  ///   result is encoded (where `completedSteps == totalSteps` and
  ///   `fraction == 1`). There's no per-byte granularity within a single
  ///   rung's decode/resample/encode step; for a page with few or no
  ///   pyramid rungs (e.g. [TiffOptimizationMode.tiledOnly]), expect just a
  ///   couple of calls rather than a smoothly increasing stream.
  static Uint8List optimize(
    TiffImage page, {
    TiffOptimizationMode mode = TiffOptimizationMode.tiledPyramid,
    int tileSize = 512,
    int minPyramidDimension = 512,
    int compression = 8,
    void Function(TiffOptimizeProgress)? onProgress,
  }) {
    if (tileSize <= 0) {
      throw ArgumentError('tileSize must be > 0');
    }
    if (minPyramidDimension <= 0) {
      throw ArgumentError('minPyramidDimension must be > 0');
    }

    var width = page.metadata.width;
    var height = page.metadata.height;
    final includesBaseLevel = mode != TiffOptimizationMode.pyramidLevelsOnly;
    final buildsSmallerRungs = mode != TiffOptimizationMode.tiledOnly;

    if (mode == TiffOptimizationMode.pyramidLevelsOnly && math.max(width, height) <= minPyramidDimension) {
      throw ArgumentError(
        'page is already at or below minPyramidDimension ($minPyramidDimension); '
        'there is no smaller pyramid level to build',
      );
    }

    var totalLevels = buildsSmallerRungs ? _countLevels(width, height, minPyramidDimension) : 1;
    if (!includesBaseLevel) totalLevels -= 1;
    // +1 reserves a step for the final TiffEncoder.encode call below, so
    // onProgress never reports completion before the result actually exists.
    final totalSteps = totalLevels + 1;
    var completedSteps = 0;
    void reportStep() {
      completedSteps++;
      onProgress?.call((completedSteps: completedSteps, totalSteps: totalSteps, fraction: completedSteps / totalSteps));
    }

    var rgba = page.decodeRgba8();
    final specs = <TiffImageSpec>[];
    if (includesBaseLevel) {
      specs.add(_tiledRgbSpec(rgba, width, height, tileSize, compression));
      reportStep();
    }

    if (buildsSmallerRungs) {
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
        reportStep();
      }
    }

    final bytes = TiffEncoder.encode(specs);
    reportStep();
    return bytes;
  }

  /// Builds the same output [optimize] does with
  /// [TiffOptimizationMode.pyramidLevelsOnly], but with no ceiling on
  /// [page]'s own size: [optimize] always decodes the whole page as one
  /// RGBA8 buffer first (see its own doc comment), which for a real
  /// multi-gigapixel page can itself be too large to safely hold in memory
  /// well before any downsampling even starts. This instead uses
  /// [BandedDownsampler] to derive the *first* rung at or below
  /// [maxDirectDecodePixels] straight from the source, decoding it in row
  /// bands (bounded by [maxBandBytes]) rather than all at once — every rung
  /// after that is small enough (by construction, since each is smaller
  /// than the last) that the normal in-memory halving [optimize] itself
  /// uses is safe to reuse for it.
  ///
  /// A rung larger than [maxDirectDecodePixels] is never produced at all,
  /// not even via banding — this cache exists to help only the far
  /// zoomed-out end a viewer's native, bounded-memory region/tile decode of
  /// the source doesn't serve well; a rung close to the source's own
  /// resolution offers little over just decoding the source directly for
  /// that same zoom range. If the source itself is already at or below
  /// [maxDirectDecodePixels], this degrades to exactly what [optimize]'s
  /// `pyramidLevelsOnly` mode would have done directly.
  ///
  /// See [optimize] for what [tileSize], [minPyramidDimension],
  /// [compression], and [onProgress] each do — identical here. Throws
  /// [ArgumentError] under the same conditions `pyramidLevelsOnly` does
  /// (invalid [tileSize]/[minPyramidDimension], or [page] already at or
  /// below [minPyramidDimension]), plus if [maxDirectDecodePixels] or
  /// [maxBandBytes] isn't positive.
  static Uint8List optimizeLargeSourcePyramidLevels(
    TiffImage page, {
    int tileSize = 512,
    int minPyramidDimension = 512,
    int compression = 8,
    int maxDirectDecodePixels = 64 * 1000 * 1000,
    int maxBandBytes = 128 * 1024 * 1024,
    void Function(TiffOptimizeProgress)? onProgress,
  }) {
    if (tileSize <= 0) {
      throw ArgumentError('tileSize must be > 0');
    }
    if (minPyramidDimension <= 0) {
      throw ArgumentError('minPyramidDimension must be > 0');
    }
    if (maxDirectDecodePixels <= 0) {
      throw ArgumentError('maxDirectDecodePixels must be > 0');
    }
    if (maxBandBytes <= 0) {
      throw ArgumentError('maxBandBytes must be > 0');
    }

    final baseWidth = page.metadata.width;
    final baseHeight = page.metadata.height;
    if (math.max(baseWidth, baseHeight) <= minPyramidDimension) {
      throw ArgumentError(
        'page is already at or below minPyramidDimension ($minPyramidDimension); '
        'there is no smaller pyramid level to build',
      );
    }

    // Always halve at least once from the true base — pyramidLevelsOnly
    // semantics never include the base resolution itself as a rung, even
    // when the base already fits maxDirectDecodePixels on its own.
    var width = math.max(1, baseWidth ~/ 2);
    var height = math.max(1, baseHeight ~/ 2);
    while (width * height > maxDirectDecodePixels && math.max(width, height) > minPyramidDimension) {
      width = math.max(1, width ~/ 2);
      height = math.max(1, height ~/ 2);
    }

    final totalLevels = _countLevels(width, height, minPyramidDimension);
    // +1 reserves a step for the final TiffEncoder.encode call below, so
    // onProgress never reports completion before the result actually exists.
    final totalSteps = totalLevels + 1;
    var completedSteps = 0;
    void reportStep() {
      completedSteps++;
      onProgress?.call((completedSteps: completedSteps, totalSteps: totalSteps, fraction: completedSteps / totalSteps));
    }

    var rgba = BandedDownsampler.downsample(page, dstWidth: width, dstHeight: height, maxBandBytes: maxBandBytes);
    final specs = <TiffImageSpec>[_tiledRgbSpec(rgba, width, height, tileSize, compression)];
    reportStep();

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
      reportStep();
    }

    final bytes = TiffEncoder.encode(specs);
    reportStep();
    return bytes;
  }

  /// How many rungs [optimize] will build for [TiffOptimizationMode.tiledPyramid]
  /// — the base resolution plus one per halving down to [minPyramidDimension]
  /// — computed up front so [optimize] can report proportional progress
  /// without guessing at how much work remains.
  static int _countLevels(int width, int height, int minPyramidDimension) {
    var levels = 1;
    while (math.max(width, height) > minPyramidDimension) {
      width = math.max(1, width ~/ 2);
      height = math.max(1, height ~/ 2);
      levels++;
    }
    return levels;
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
