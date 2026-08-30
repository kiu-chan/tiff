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

/// Which phase of [TiffDisplayOptimizer.optimize] (or
/// [TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels]) a
/// [TiffOptimizeProgress] update was reported from.
enum TiffOptimizeStage {
  /// Reading the source page's pixels: one whole-page decode for [TiffDisplayOptimizer.optimize],
  /// or one row band at a time for [TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels]'s
  /// first (banded) rung.
  decoding,

  /// Box-filtering an already-decoded rung down to the next, half-sized one.
  downsampling,

  /// Tiling and compressing a rung's pixels into the output file — by far
  /// the largest source of otherwise-invisible work in a big pyramid (see
  /// `TileWriter`), which is why it's broken out per tile here rather than
  /// reported as a single opaque step the way it used to be.
  encoding,
}

/// Progress reported by [TiffDisplayOptimizer.optimize] (or
/// [TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels]) as it works.
///
/// [level] (0-based) and [levelCount] locate which pyramid rung this update
/// belongs to, out of how many rungs the call will build in total —
/// consistent across all three stages, so a rung's decode, downsample, and
/// encode updates all carry the same [level]. [stepIndex]/[stepCount]
/// (1-based) report progress *within* [stage] for that rung alone: the
/// band number out of the total bands for [TiffOptimizeStage.decoding], or
/// the tile number out of that rung's total tile count for
/// [TiffOptimizeStage.encoding] (always `(1, 1)` for
/// [TiffOptimizeStage.downsampling], which has no further sub-steps of its
/// own).
///
/// [fraction] is the overall 0..1 progress across the *whole* call — every
/// stage and every rung — weighted by how many pixels each phase actually
/// touches (a banded decode of a 200-megapixel source counts for far more
/// than compressing one of the pyramid's smaller rungs), so it tracks real
/// elapsed time much more closely than counting "rungs done" ever could.
/// It reaches exactly `1.0` on the final call, once the whole result is
/// encoded.
typedef TiffOptimizeProgress = ({
  TiffOptimizeStage stage,
  int level,
  int levelCount,
  int stepIndex,
  int stepCount,
  double fraction,
});

/// Accumulates pixel-weighted "units" of completed work across every stage
/// of one [TiffDisplayOptimizer.optimize]/`optimizeLargeSourcePyramidLevels`
/// call and turns each [report] into a [TiffOptimizeProgress] with an
/// overall [TiffOptimizeProgress.fraction] — a thin wrapper mainly so
/// neither call site has to carry a running `completedUnits` variable and
/// re-derive the same record-building call by hand at every one of its own
/// (several) progress call sites.
class _ProgressTracker {
  final void Function(TiffOptimizeProgress)? _onProgress;
  final int _levelCount;
  final int _totalUnits;
  int _completedUnits = 0;

  _ProgressTracker(this._onProgress, this._levelCount, this._totalUnits);

  void report({
    required TiffOptimizeStage stage,
    required int level,
    required int stepIndex,
    required int stepCount,
    required int units,
  }) {
    _completedUnits += units;
    final onProgress = _onProgress;
    if (onProgress == null) return;
    onProgress((
      stage: stage,
      level: level,
      levelCount: _levelCount,
      stepIndex: stepIndex,
      stepCount: stepCount,
      fraction: _totalUnits == 0
          ? 1.0
          : (_completedUnits / _totalUnits).clamp(0.0, 1.0),
    ));
  }
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
  /// - [onProgress]: called with a [TiffOptimizeProgress] repeatedly as work
  ///   completes — see its own doc comment for what each field means and how
  ///   [TiffOptimizeProgress.fraction] is weighted. The very first call
  ///   isn't until after the initial whole-page decode, which for a large
  ///   page can itself take a while with nothing reported before it; when
  ///   [page] might be too big to decode as one buffer at all, use
  ///   [optimizeLargeSourcePyramidLevels] instead, which reports progress
  ///   *during* that decode too.
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

    final baseWidth = page.metadata.width;
    final baseHeight = page.metadata.height;
    final includesBaseLevel = mode != TiffOptimizationMode.pyramidLevelsOnly;
    final buildsSmallerRungs = mode != TiffOptimizationMode.tiledOnly;

    if (mode == TiffOptimizationMode.pyramidLevelsOnly &&
        math.max(baseWidth, baseHeight) <= minPyramidDimension) {
      throw ArgumentError(
        'page is already at or below minPyramidDimension ($minPyramidDimension); '
        'there is no smaller pyramid level to build',
      );
    }

    // The full base -> ... -> minPyramidDimension halving sequence, derived
    // purely from dimensions (no decoding yet) — both to know the output
    // level count upfront (for TiffOptimizeProgress.levelCount) and to
    // weight each phase's progress by the pixels it actually touches (see
    // _ProgressTracker).
    final fullSequence = buildsSmallerRungs
        ? _levelDimensions(baseWidth, baseHeight, minPyramidDimension)
        : [(baseWidth, baseHeight)];
    final outputLevels = includesBaseLevel
        ? fullSequence
        : fullSequence.sublist(1);

    final tracker = _ProgressTracker(
      onProgress,
      outputLevels.length,
      baseWidth * baseHeight +
          _downsampleUnits(fullSequence) +
          _encodeUnits(outputLevels, tileSize),
    );

    var rgba = page.decodeRgba8();
    tracker.report(
      stage: TiffOptimizeStage.decoding,
      level: 0,
      stepIndex: 1,
      stepCount: 1,
      units: baseWidth * baseHeight,
    );

    final specs = <TiffImageSpec>[];
    var width = baseWidth;
    var height = baseHeight;
    var outputIndex = 0;
    if (includesBaseLevel) {
      specs.add(_tiledRgbSpec(rgba, width, height, tileSize, compression));
      outputIndex++;
    }

    if (buildsSmallerRungs) {
      while (math.max(width, height) > minPyramidDimension) {
        final nextWidth = math.max(1, width ~/ 2);
        final nextHeight = math.max(1, height ~/ 2);
        final sourceUnits = width * height;
        rgba = ImageResampler.downsampleRgba8(
          rgba,
          srcWidth: width,
          srcHeight: height,
          dstWidth: nextWidth,
          dstHeight: nextHeight,
        );
        width = nextWidth;
        height = nextHeight;
        tracker.report(
          stage: TiffOptimizeStage.downsampling,
          level: outputIndex,
          stepIndex: 1,
          stepCount: 1,
          units: sourceUnits,
        );
        specs.add(_tiledRgbSpec(rgba, width, height, tileSize, compression));
        outputIndex++;
      }
    }

    final bytes = TiffEncoder.encode(
      specs,
      onChunkEncoded: (pageIndex, pageCount, chunkIndex, chunkCount) =>
          tracker.report(
            stage: TiffOptimizeStage.encoding,
            level: pageIndex,
            stepIndex: chunkIndex,
            stepCount: chunkCount,
            units: tileSize * tileSize,
          ),
    );
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
    while (width * height > maxDirectDecodePixels &&
        math.max(width, height) > minPyramidDimension) {
      width = math.max(1, width ~/ 2);
      height = math.max(1, height ~/ 2);
    }

    final outputLevels = _levelDimensions(width, height, minPyramidDimension);
    final tracker = _ProgressTracker(
      onProgress,
      outputLevels.length,
      baseWidth * baseHeight +
          _downsampleUnits(outputLevels) +
          _encodeUnits(outputLevels, tileSize),
    );

    final rgba = BandedDownsampler.downsample(
      page,
      dstWidth: width,
      dstHeight: height,
      maxBandBytes: maxBandBytes,
      onBand: (bandIndex, bandCount, bandSrcRows) => tracker.report(
        stage: TiffOptimizeStage.decoding,
        level: 0,
        stepIndex: bandIndex,
        stepCount: bandCount,
        units: bandSrcRows * baseWidth,
      ),
    );
    return _buildPyramidFromFirstRung(
      firstRungRgba: rgba,
      width: width,
      height: height,
      minPyramidDimension: minPyramidDimension,
      tileSize: tileSize,
      compression: compression,
      tracker: tracker,
    );
  }

  /// The same output [optimizeLargeSourcePyramidLevels] builds, but decodes
  /// its first (banded) rung across up to [workerCount] isolates instead of
  /// one row-band at a time on the caller's own — see
  /// [BandedDownsampler.downsampleParallel], which this delegates to for
  /// that step. Real multi-core parallelism for what's usually the single
  /// most expensive part of building a pyramid for a truly huge source: the
  /// decode/decompress work needed to read that first rung's worth of
  /// pixels off of it in the first place.
  ///
  /// Bit-for-bit identical output to [optimizeLargeSourcePyramidLevels]
  /// given the same [maxBandBytes] — only the decode step's wall time (and
  /// which isolate does the work) differs, never what gets computed.
  ///
  /// Unlike [optimizeLargeSourcePyramidLevels], this needs [filePath]
  /// alongside [page]: each worker isolate opens its own handle on it
  /// independently (a decoded [TiffImage] and its file handle can't cross
  /// an isolate boundary), the same reason
  /// [BandedDownsampler.downsampleParallel] needs a path rather than a
  /// [TiffImage] for that same step. [pageIndex] must refer to the same
  /// page [page] itself came from (0 for the common single/first-page
  /// case) — this doesn't (and safely can't) verify that for you, since
  /// nothing here re-opens [filePath] on this isolate to check.
  ///
  /// [workerCount] and [setUpIsolate] are forwarded to
  /// [BandedDownsampler.downsampleParallel] as-is — see its doc comment,
  /// especially for what a static/top-level-only [setUpIsolate] means if
  /// [page]'s source needs one (e.g. JPEG-compressed: pass
  /// `TiffImageAdapter.enableJpegSupport`). Picking a sensible [workerCount]
  /// (and a [maxBandBytes] that keeps `workerCount * maxBandBytes` within
  /// whatever memory budget is actually available) is the caller's call —
  /// this makes no assumption about how many cores or how much memory is
  /// safe to use at once, mirroring [BandedDownsampler.downsampleParallel]'s
  /// own philosophy (see its doc comment) and
  /// `TiffAutoDecodeBudget.recommend`, a ready-made way to derive both from
  /// actual idle system memory and CPU count.
  ///
  /// See [optimizeLargeSourcePyramidLevels] for what every other parameter
  /// does and which conditions throw [ArgumentError] — identical here.
  static Future<Uint8List> optimizeLargeSourcePyramidLevelsParallel(
    TiffImage page,
    String filePath, {
    int pageIndex = 0,
    int tileSize = 512,
    int minPyramidDimension = 512,
    int compression = 8,
    int maxDirectDecodePixels = 64 * 1000 * 1000,
    int maxBandBytes = 128 * 1024 * 1024,
    required int workerCount,
    void Function()? setUpIsolate,
    void Function(TiffOptimizeProgress)? onProgress,
  }) async {
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

    var width = math.max(1, baseWidth ~/ 2);
    var height = math.max(1, baseHeight ~/ 2);
    while (width * height > maxDirectDecodePixels &&
        math.max(width, height) > minPyramidDimension) {
      width = math.max(1, width ~/ 2);
      height = math.max(1, height ~/ 2);
    }

    final outputLevels = _levelDimensions(width, height, minPyramidDimension);
    final tracker = _ProgressTracker(
      onProgress,
      outputLevels.length,
      baseWidth * baseHeight +
          _downsampleUnits(outputLevels) +
          _encodeUnits(outputLevels, tileSize),
    );

    final rgba = await BandedDownsampler.downsampleParallel(
      filePath: filePath,
      pageIndex: pageIndex,
      dstWidth: width,
      dstHeight: height,
      maxBandBytes: maxBandBytes,
      workerCount: workerCount,
      setUpIsolate: setUpIsolate,
      onBand: (bandIndex, bandCount, bandSrcRows) => tracker.report(
        stage: TiffOptimizeStage.decoding,
        level: 0,
        stepIndex: bandIndex,
        stepCount: bandCount,
        units: bandSrcRows * baseWidth,
      ),
    );
    return _buildPyramidFromFirstRung(
      firstRungRgba: rgba,
      width: width,
      height: height,
      minPyramidDimension: minPyramidDimension,
      tileSize: tileSize,
      compression: compression,
      tracker: tracker,
    );
  }

  /// The shared tail of [optimizeLargeSourcePyramidLevels] and
  /// [optimizeLargeSourcePyramidLevelsParallel] once each has its own
  /// first rung's pixels in hand ([firstRungRgba], `width x height`) —
  /// halves it down to [minPyramidDimension] the same in-memory way
  /// [optimize] does for every rung after its own first, then encodes
  /// every rung into one TIFF. The two callers differ only in *how* they
  /// got [firstRungRgba]; everything from here on is identical.
  static Uint8List _buildPyramidFromFirstRung({
    required Uint8List firstRungRgba,
    required int width,
    required int height,
    required int minPyramidDimension,
    required int tileSize,
    required int compression,
    required _ProgressTracker tracker,
  }) {
    var rgba = firstRungRgba;
    final specs = <TiffImageSpec>[
      _tiledRgbSpec(rgba, width, height, tileSize, compression),
    ];
    var outputIndex = 1;

    while (math.max(width, height) > minPyramidDimension) {
      final nextWidth = math.max(1, width ~/ 2);
      final nextHeight = math.max(1, height ~/ 2);
      final sourceUnits = width * height;
      rgba = ImageResampler.downsampleRgba8(
        rgba,
        srcWidth: width,
        srcHeight: height,
        dstWidth: nextWidth,
        dstHeight: nextHeight,
      );
      width = nextWidth;
      height = nextHeight;
      tracker.report(
        stage: TiffOptimizeStage.downsampling,
        level: outputIndex,
        stepIndex: 1,
        stepCount: 1,
        units: sourceUnits,
      );
      specs.add(_tiledRgbSpec(rgba, width, height, tileSize, compression));
      outputIndex++;
    }

    return TiffEncoder.encode(
      specs,
      onChunkEncoded: (pageIndex, pageCount, chunkIndex, chunkCount) =>
          tracker.report(
            stage: TiffOptimizeStage.encoding,
            level: pageIndex,
            stepIndex: chunkIndex,
            stepCount: chunkCount,
            units: tileSize * tileSize,
          ),
    );
  }

  /// The base -> ... -> minPyramidDimension halving sequence, as a list of
  /// `(width, height)` pairs starting from `(width, height)` itself —
  /// computed purely from dimensions, no decoding, so both [optimize] and
  /// [optimizeLargeSourcePyramidLevels] can know their output level count
  /// (and weight progress by each level's pixel count) before doing any
  /// actual work.
  static List<(int, int)> _levelDimensions(
    int width,
    int height,
    int minPyramidDimension,
  ) {
    final dims = [(width, height)];
    while (math.max(width, height) > minPyramidDimension) {
      width = math.max(1, width ~/ 2);
      height = math.max(1, height ~/ 2);
      dims.add((width, height));
    }
    return dims;
  }

  /// The total pixel-weighted "units" of downsample work a halving
  /// [sequence] (as returned by [_levelDimensions]) requires: each rung
  /// after the first is built by box-filtering the *previous* rung, so it
  /// costs one unit per pixel of that previous, larger rung — matching what
  /// [_ProgressTracker.report] is fed at each `TiffOptimizeStage.downsampling`
  /// call in [optimize]/[optimizeLargeSourcePyramidLevels] exactly, so the
  /// running total this promises up front is always reached, never
  /// overshot or undershot.
  static int _downsampleUnits(List<(int, int)> sequence) {
    var units = 0;
    for (var i = 1; i < sequence.length; i++) {
      final (prevWidth, prevHeight) = sequence[i - 1];
      units += prevWidth * prevHeight;
    }
    return units;
  }

  /// The total pixel-weighted "units" of encode work every level in
  /// [levels] requires at [tileSize]: each tile — including a padded edge
  /// tile — costs exactly `tileSize * tileSize` units, matching the flat
  /// per-tile weight `TiffEncoder.encode`'s `onChunkEncoded` callback is
  /// charged at each call in [optimize]/[optimizeLargeSourcePyramidLevels],
  /// so this sum and that running total always agree.
  static int _encodeUnits(List<(int, int)> levels, int tileSize) {
    var units = 0;
    for (final (width, height) in levels) {
      final tilesAcross = (width + tileSize - 1) ~/ tileSize;
      final tilesDown = (height + tileSize - 1) ~/ tileSize;
      units += tilesAcross * tilesDown * tileSize * tileSize;
    }
    return units;
  }

  static TiffImageSpec _tiledRgbSpec(
    Uint8List rgba,
    int width,
    int height,
    int tileSize,
    int compression,
  ) {
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
