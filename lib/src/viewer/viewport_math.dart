import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

/// On-screen size, in logical pixels, below which a rung's tiles are merged
/// into composites — see [selectSpan].
const minTileScreenSize = 64.0;

/// One resolution rung as the viewer sees it: a grid of equally-sized tiles
/// (the last row/column cropped to the rung's edge) plus how many base
/// pixels one of its texels covers along each axis.
///
/// A strip-organized rung ([stripBands]) is cut into bands whose height is
/// aligned to its strips and whose width is capped to stay inside GPU
/// texture limits — a strip can't be partially decoded, so the worker
/// decodes a composite's columns together, one band row at a time.
///
/// [width]/[height] are the rung's stored size, which may include padding
/// past the base image's edge (see `rungDownsample`); painting clips that
/// away.
class LodLevel {
  final int width;
  final int height;
  final int tileWidth;
  final int tileHeight;
  final double downsampleX;
  final double downsampleY;
  final bool stripBands;

  /// Which page of the source's pyramid the pixels come from, or
  /// `overviewRung` for the overview a worker keeps in memory.
  final int rung;

  /// Whether the rung's tiles are standalone JPEG streams the platform codec
  /// can decode — at 1/2 to 1/8 scale, far faster than a full decode.
  final bool nativeJpeg;

  const LodLevel({
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileHeight,
    required this.downsampleX,
    required this.downsampleY,
    this.stripBands = false,
    this.rung = 0,
    this.nativeJpeg = false,
  });
}

/// An inclusive range of tile indices.
class TileRange {
  final int minTx;
  final int maxTx;
  final int minTy;
  final int maxTy;

  const TileRange({
    required this.minTx,
    required this.maxTx,
    required this.minTy,
    required this.maxTy,
  });

  int get count => (maxTx - minTx + 1) * (maxTy - minTy + 1);

  bool contains(int tx, int ty) =>
      tx >= minTx && tx <= maxTx && ty >= minTy && ty <= maxTy;
}

/// [level]'s tile grid coarsened to composites of `2^span` x `2^span` of its
/// tiles (see [selectSpan]); `span == 0` is the rung's own grid.
class LodGrid {
  final LodLevel level;
  final int span;

  const LodGrid(this.level, this.span);

  int get tileWidth => level.tileWidth << span;
  int get tileHeight => level.tileHeight << span;
  int get tilesAcross => (level.width + tileWidth - 1) ~/ tileWidth;
  int get tilesDown => (level.height + tileHeight - 1) ~/ tileHeight;

  /// The tiles intersecting a [viewportSize] viewport that shows the base
  /// image at [scale] screen pixels per base pixel, with base point [origin]
  /// at its top-left corner — grown by [margin] tiles on every side — or
  /// null if the viewport doesn't overlap the image at all.
  TileRange? visible(
    Size viewportSize,
    double scale,
    Offset origin, {
    int margin = 0,
  }) {
    final left = origin.dx / level.downsampleX;
    final top = origin.dy / level.downsampleY;
    final right = (origin.dx + viewportSize.width / scale) / level.downsampleX;
    final bottom =
        (origin.dy + viewportSize.height / scale) / level.downsampleY;
    if (right <= 0 ||
        bottom <= 0 ||
        left >= level.width ||
        top >= level.height) {
      return null;
    }
    final lastTx = tilesAcross - 1;
    final lastTy = tilesDown - 1;
    return TileRange(
      minTx: ((left / tileWidth).floor() - margin).clamp(0, lastTx),
      maxTx: ((right / tileWidth).floor() + margin).clamp(0, lastTx),
      minTy: ((top / tileHeight).floor() - margin).clamp(0, lastTy),
      maxTy: ((bottom / tileHeight).floor() + margin).clamp(0, lastTy),
    );
  }
}

/// How many times over — as a power-of-two shift per side — to merge a
/// rung's tiles into composites so each spans at least [minTileScreenSize]
/// screen pixels, given [tileScreenSize], the on-screen size of one tile.
///
/// Every tile has a fixed cost however small it's drawn: a worker round
/// trip, a texture upload, a draw call. A page whose pyramid is too shallow
/// for the current zoom (a single-rung file seen zoomed out, or a strip page
/// cut into bands a few rows tall) would otherwise need thousands of tiles a
/// few pixels across; composites keep the count proportional to the screen.
int selectSpan(double tileScreenSize, {int maxSpan = 10}) {
  var span = 0;
  while (span < maxSpan && tileScreenSize * (1 << span) < minTileScreenSize) {
    span++;
  }
  return span;
}

/// The deepest downscale — as a power-of-two shift, so a tile is delivered
/// at `1 / 2^shift` of its stored size — that still leaves each delivered
/// pixel no bigger than [maxUpsample] screen pixels, capped at
/// [maxReduction]. [screenPixelsPerTexel] is how many screen pixels one of
/// the chosen rung's texels spans; with pyramid steps wider than 2x (or no
/// pyramid at all) that's often far below [maxUpsample], and shipping every
/// texel to the GPU would only burn memory on detail the screen can't show.
int selectReduction(
  double screenPixelsPerTexel, {
  required double maxUpsample,
  int maxReduction = 3,
}) {
  var shift = 0;
  while (shift < maxReduction &&
      screenPixelsPerTexel * (1 << (shift + 1)) <= maxUpsample) {
    shift++;
  }
  return shift;
}

/// An [extent]-pixel dimension after a [reduction]-shift downscale, rounded
/// up.
int reducedExtent(int extent, int reduction) =>
    (extent + (1 << reduction) - 1) >> reduction;

/// Up to [limit] tiles of [range], nearest to ([centerTx], [centerTy]) (in
/// fractional tile units) first — expanding square rings out from the center
/// tile — skipping any inside [exclude].
///
/// Costs O([limit] + ring count), never O(tiles in [range]): a zoomed-out
/// view of a page with too shallow a pyramid can span tens of thousands of
/// tiles, and enumerating (let alone sorting) all of them on every viewport
/// change would itself stall the UI.
List<(int, int)> tilesNearestFirst(
  TileRange range,
  double centerTx,
  double centerTy,
  int limit, {
  TileRange? exclude,
}) {
  final result = <(int, int)>[];
  if (limit <= 0) return result;
  final cx = centerTx.floor().clamp(range.minTx, range.maxTx);
  final cy = centerTy.floor().clamp(range.minTy, range.maxTy);
  final maxRadius = [
    cx - range.minTx,
    range.maxTx - cx,
    cy - range.minTy,
    range.maxTy - cy,
  ].reduce(math.max);

  bool add(int tx, int ty) {
    if (exclude != null && exclude.contains(tx, ty)) return false;
    result.add((tx, ty));
    return result.length >= limit;
  }

  for (var r = 0; r <= maxRadius; r++) {
    final left = (cx - r).clamp(range.minTx, range.maxTx);
    final right = (cx + r).clamp(range.minTx, range.maxTx);
    // Top and bottom rows of the ring (just the center tile when r == 0).
    for (final ty in r == 0 ? [cy] : [cy - r, cy + r]) {
      if (ty < range.minTy || ty > range.maxTy) continue;
      for (var tx = left; tx <= right; tx++) {
        if (add(tx, ty)) return result;
      }
    }
    if (r == 0) continue;
    // Left and right columns, between those rows.
    final top = (cy - r + 1).clamp(range.minTy, range.maxTy);
    final bottom = (cy + r - 1).clamp(range.minTy, range.maxTy);
    for (final tx in [cx - r, cx + r]) {
      if (tx < range.minTx || tx > range.maxTx) continue;
      for (var ty = top; ty <= bottom; ty++) {
        if (add(tx, ty)) return result;
      }
    }
  }
  return result;
}
