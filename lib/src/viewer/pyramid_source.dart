import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../image/image_metadata.dart';
import '../image/photometric.dart';
import '../image/planar_configuration.dart';
import '../image/tiff_image.dart';
import '../io/file_byte_source.dart';
import '../optimize/banded_downsampler.dart';
import '../region/tiff_region.dart';
import '../tiff_decoder.dart';
import '../tiff_document.dart';
import 'viewport_math.dart';

/// Where a viewer's pixels come from — plain values only, so the same
/// description can be handed to every worker isolate, each of which opens
/// its own file handles (a [TiffDocument] can't cross an isolate boundary).
typedef PyramidSourceConfig = ({
  String filePath,
  int pageIndex,
  String? pyramidLevelsPath,
  void Function()? setUpIsolate,
});

/// What the main isolate needs to know about a [PyramidSourceConfig] before
/// anything is decoded: the base page, every level's tile geometry (largest
/// first), and how the overview is produced — [overviewLevel] is its
/// geometry, and it is also the last of [levels] when it stands in for
/// missing small rungs (see [describeRungs]).
typedef PyramidSourceInfo = ({
  TiffImageMetadata base,
  List<LodLevel> levels,
  OverviewPlan overview,
  LodLevel overviewLevel,
});

/// Which rung the overview is derived from and its output size. [sparse]
/// means it is only a blocky sample of scattered tiles — a quick placeholder,
/// never a substitute for real pixels at any zoom.
typedef OverviewPlan = ({int rung, int width, int height, bool sparse});

/// [LodLevel.rung] of the level served from a worker's in-memory overview.
const overviewRung = -1;

/// Longest side of the overview decoded when a page's pyramid has no rung at
/// most this long — it then becomes a level of its own, so a zoomed-out view
/// never has to be assembled from the huge rungs.
const overviewMaxDimension = 4096;

/// Longest side of the preview painted under loading tiles and shown in the
/// minimap.
const previewMaxDimension = 1024;

/// Tile size the in-memory overview level is cut into.
const overviewTileSize = 512;

/// Above this many pixels, a tiled rung's overview is sparsely sampled
/// instead of decoded whole — a pyramid-less multi-gigapixel page would
/// otherwise take minutes to show anything.
const maxFullOverviewPixels = 128 * 1000 * 1000;

/// Largest raw decode one strip band aims for (see [stripBandRows]).
const maxStripBandBytes = 16 * 1024 * 1024;

/// Longest side of any one tile the viewer uploads — comfortably inside every
/// GPU's texture size limit, however wide a strip-organized page is.
const maxTileExtent = 4096;

/// An opened [PyramidSourceConfig]: the documents it reads plus the pages
/// forming its pyramid, largest first — identical, rung for rung, in every
/// isolate that opens the same config.
class PyramidSource {
  final TiffDocument _document;
  final TiffDocument? _extraDocument;
  final List<TiffImage> rungs;

  PyramidSource._(this._document, this._extraDocument, this.rungs);

  factory PyramidSource.open(PyramidSourceConfig config) {
    final document = TiffDecoder.decodeSource(
      FileByteSource.open(File(config.filePath)),
    );
    TiffDocument? extraDocument;
    try {
      final pages = document.images;
      if (config.pageIndex < 0 || config.pageIndex >= pages.length) {
        throw ArgumentError.value(
          config.pageIndex,
          'pageIndex',
          'out of range (page count: ${pages.length})',
        );
      }
      final extraPath = config.pyramidLevelsPath;
      if (extraPath != null) {
        extraDocument = TiffDecoder.decodeSource(
          FileByteSource.open(File(extraPath)),
        );
      }
      return PyramidSource._(
        document,
        extraDocument,
        findPyramidRungs(
          pages,
          baseIndex: config.pageIndex,
          extraPages: extraDocument?.images ?? const [],
        ),
      );
    } catch (_) {
      document.close();
      extraDocument?.close();
      rethrow;
    }
  }

  void close() {
    _document.close();
    _extraDocument?.close();
  }
}

/// Opens [config] just long enough to describe it.
PyramidSourceInfo describePyramidSource(PyramidSourceConfig config) {
  final source = PyramidSource.open(config);
  try {
    return describeRungs([for (final rung in source.rungs) rung.metadata]);
  } finally {
    source.close();
  }
}

/// The display levels and overview for [rungs] (base first, as returned by
/// [findPyramidRungs]) — deterministic, so every isolate derives the same.
///
/// A pyramid that already reaches down to [overviewMaxDimension] serves
/// every zoom from its own rungs, and only a small preview is decoded. One
/// that stops short (or a page with no pyramid at all) gets an overview up
/// to [overviewMaxDimension] long, box-filtered from its smallest rung and
/// kept in memory as an extra, coarsest level — unless that rung is too big
/// to decode whole, in which case the overview is only a sparse placeholder.
PyramidSourceInfo describeRungs(List<TiffImageMetadata> rungs) {
  final base = rungs.first;
  final levels = [
    for (final (i, rung) in rungs.indexed) lodLevelFor(rung, base, rung: i),
  ];
  final smallest = rungs.last;
  final hasSmallRung =
      math.max(smallest.width, smallest.height) <= overviewMaxDimension;
  final plan = planOverview(
    rungs,
    maxDimension: hasSmallRung ? previewMaxDimension : overviewMaxDimension,
  );
  final source = levels[plan.rung];
  final overviewLevel = LodLevel(
    width: plan.width,
    height: plan.height,
    tileWidth: overviewTileSize,
    tileHeight: overviewTileSize,
    downsampleX: source.downsampleX * source.width / plan.width,
    downsampleY: source.downsampleY * source.height / plan.height,
    rung: overviewRung,
  );
  return (
    base: base,
    levels: [...levels, if (!hasSmallRung && !plan.sparse) overviewLevel],
    overview: plan,
    overviewLevel: overviewLevel,
  );
}

/// How many base pixels one pixel of [rung] covers along each axis, or null
/// if [rung] isn't a reduced copy of [base].
///
/// Many scanners (Philips, for one) pad every rung out to whole tiles, so a
/// rung's size isn't the base size divided by its downsample: a 4096 x 3584
/// rung of a 131072 x 100352 base is a 32x reduction with 448 rows of
/// padding, not 28x vertically. So a power-of-two reduction whose padding is
/// under one tile wins; otherwise the plain size ratio is used, as long as
/// both axes shrink by about the same factor (repeated halving drifts a
/// small rung's ratio a little; an unrelated label or macro image usually
/// differs far more).
(double, double)? rungDownsample(
  TiffImageMetadata rung,
  TiffImageMetadata base,
) {
  if (rung.width >= base.width || rung.height > base.height) return null;
  final ratio = base.width / rung.width;
  final powerOfTwo = math
      .pow(2, (math.log(ratio) / math.ln2).round())
      .toDouble();
  bool padded(int stored, int baseExtent, int? tileExtent) {
    final content = baseExtent / powerOfTwo;
    return stored >= content - 1 && stored < content + (tileExtent ?? 1);
  }

  if (padded(rung.width, base.width, rung.tileWidth) &&
      padded(rung.height, base.height, rung.tileLength)) {
    return (powerOfTwo, powerOfTwo);
  }
  final downsampleY = base.height / rung.height;
  if ((ratio - downsampleY).abs() / ratio <= 0.2) return (ratio, downsampleY);
  return null;
}

/// Page [baseIndex] of [pages] followed by every other page of [pages] and
/// [extraPages] that is a reduced copy of it (see [rungDownsample]) —
/// largest first, one page per distinct width.
///
/// [extraPages] is typically a sidecar built by
/// `TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels` for a page that
/// has no pyramid of its own.
List<TiffImage> findPyramidRungs(
  List<TiffImage> pages, {
  int baseIndex = 0,
  List<TiffImage> extraPages = const [],
}) {
  final base = pages[baseIndex];
  final candidates = [
    for (final page in [...pages, ...extraPages])
      if (rungDownsample(page.metadata, base.metadata) != null) page,
  ]..sort((a, b) => b.metadata.width.compareTo(a.metadata.width));
  final rungs = [base];
  for (final page in candidates) {
    if (page.metadata.width < rungs.last.metadata.width) rungs.add(page);
  }
  return rungs;
}

/// [rung]'s tile grid for display: its own tiles if it's tiled, otherwise
/// strip-aligned bands (see [stripBandRows]) at most [maxTileExtent] wide.
/// [rung] is its index among the source's rungs.
LodLevel lodLevelFor(
  TiffImageMetadata metadata,
  TiffImageMetadata base, {
  int rung = 0,
}) {
  final tiled = metadata.isTiled;
  final (downsampleX, downsampleY) =
      rungDownsample(metadata, base) ??
      (base.width / metadata.width, base.height / metadata.height);
  return LodLevel(
    width: metadata.width,
    height: metadata.height,
    tileWidth: tiled
        ? metadata.tileWidth!
        : math.min(metadata.width, maxTileExtent),
    tileHeight: tiled ? metadata.tileLength! : stripBandRows(metadata),
    downsampleX: downsampleX,
    downsampleY: downsampleY,
    stripBands: !tiled,
    rung: rung,
    nativeJpeg: supportsNativeJpegTiles(metadata),
  );
}

/// Whether [metadata]'s tiles can go straight to a platform JPEG codec (see
/// `TiffImage.readTileJpeg`): tiled new-style JPEG, chunky, 8-bit YCbCr/RGB
/// or grayscale — what whole-slide scanners write.
bool supportsNativeJpegTiles(TiffImageMetadata metadata) {
  if (!metadata.isTiled ||
      metadata.compression != 7 ||
      metadata.planarConfiguration != TiffPlanarConfiguration.chunky ||
      metadata.bitsPerSample.any((bits) => bits != 8)) {
    return false;
  }
  return switch (metadata.samplesPerPixel) {
    3 =>
      metadata.photometric == TiffPhotometric.ycbcr ||
          metadata.photometric == TiffPhotometric.rgb,
    1 => metadata.photometric == TiffPhotometric.blackIsZero,
    _ => false,
  };
}

/// Rows per display band of a strip-organized page: whole strips grouped up
/// to about [maxStripBandBytes] of raw decode, so no strip is ever
/// decompressed twice for the same band — unless a single strip is itself
/// larger than that, in which case bounded memory wins and the band is cut
/// by rows instead. Never more than [maxTileExtent] rows.
int stripBandRows(TiffImageMetadata metadata) {
  final maxBits = metadata.bitsPerSample.isEmpty
      ? 8
      : metadata.bitsPerSample.reduce(math.max);
  final bytesPerSample = maxBits <= 8 ? 1 : (maxBits <= 16 ? 2 : 4);
  // Raw samples plus the RGBA8 conversion alive alongside them.
  final bytesPerRow =
      metadata.width * (metadata.samplesPerPixel * bytesPerSample + 4);
  final rowsPerStrip = math.min(
    math.max(metadata.rowsPerStrip, 1),
    metadata.height,
  );
  final stripBytes = rowsPerStrip * bytesPerRow;
  int rows = stripBytes <= maxStripBandBytes
      ? rowsPerStrip * math.max<int>(1, maxStripBandBytes ~/ stripBytes)
      : math.max<int>(1, maxStripBandBytes ~/ bytesPerRow);
  if (rows > maxTileExtent) {
    rows = rowsPerStrip <= maxTileExtent
        ? rowsPerStrip * (maxTileExtent ~/ rowsPerStrip)
        : maxTileExtent;
  }
  return math.min(math.max(rows, 1), metadata.height);
}

/// Picks the smallest rung whose longest side is still at least
/// [maxDimension] (or the base rung, for a page smaller than that) and the
/// overview size it shrinks to.
OverviewPlan planOverview(
  List<TiffImageMetadata> rungs, {
  int maxDimension = overviewMaxDimension,
}) {
  var rung = 0;
  for (var i = rungs.length - 1; i >= 0; i--) {
    if (math.max(rungs[i].width, rungs[i].height) >= maxDimension) {
      rung = i;
      break;
    }
  }
  final metadata = rungs[rung];
  final longest = math.max(metadata.width, metadata.height);
  if (longest <= maxDimension) {
    return (
      rung: rung,
      width: metadata.width,
      height: metadata.height,
      sparse: false,
    );
  }
  final scale = maxDimension / longest;
  return (
    rung: rung,
    width: (metadata.width * scale).round().clamp(1, metadata.width),
    height: (metadata.height * scale).round().clamp(1, metadata.height),
    sparse:
        metadata.isTiled &&
        metadata.width * metadata.height > maxFullOverviewPixels,
  );
}

/// Decodes [plan]'s overview from [rung] as RGBA8: whole if it's already
/// overview-sized, box-filtered in bounded-memory bands otherwise, or
/// sparsely sampled when [OverviewPlan.sparse].
Uint8List decodeOverview(TiffImage rung, OverviewPlan plan) {
  final metadata = rung.metadata;
  if (plan.width == metadata.width && plan.height == metadata.height) {
    return rung.decodeRegionRgba8(TiffRegion.fullImage(metadata));
  }
  if (!plan.sparse) {
    return BandedDownsampler.downsample(
      rung,
      dstWidth: plan.width,
      dstHeight: plan.height,
      maxBandBytes: 64 * 1024 * 1024,
    );
  }
  return _sparseOverview(rung, plan.width, plan.height);
}

/// Decodes an evenly spaced grid of at most 24 x 24 tiles and stretches each
/// across the block of output pixels it stands in for — blocky, but ready in
/// moments however many tiles the rung has.
Uint8List _sparseOverview(TiffImage rung, int outWidth, int outHeight) {
  const samplesPerAxis = 24;
  final metadata = rung.metadata;
  final tileWidth = metadata.tileWidth!;
  final tileLength = metadata.tileLength!;
  final tileCols = (metadata.width + tileWidth - 1) ~/ tileWidth;
  final tileRows = (metadata.height + tileLength - 1) ~/ tileLength;
  final sampleCols = math.min(tileCols, samplesPerAxis);
  final sampleRows = math.min(tileRows, samplesPerAxis);
  final output = Uint8List(outWidth * outHeight * 4);

  for (var sy = 0; sy < sampleRows; sy++) {
    final srcY = (sy * tileRows ~/ sampleRows) * tileLength;
    final th = math.min(tileLength, metadata.height - srcY);
    final outY0 = sy * outHeight ~/ sampleRows;
    final outY1 = math.min(
      outHeight,
      math.max(outY0 + 1, (sy + 1) * outHeight ~/ sampleRows),
    );
    for (var sx = 0; sx < sampleCols; sx++) {
      final srcX = (sx * tileCols ~/ sampleCols) * tileWidth;
      final tw = math.min(tileWidth, metadata.width - srcX);
      final outX0 = sx * outWidth ~/ sampleCols;
      final outX1 = math.min(
        outWidth,
        math.max(outX0 + 1, (sx + 1) * outWidth ~/ sampleCols),
      );
      final Uint8List tile;
      try {
        tile = rung.decodeRegionRgba8(
          TiffRegion(x: srcX, y: srcY, width: tw, height: th),
        );
      } catch (_) {
        continue;
      }
      for (var oy = outY0; oy < outY1; oy++) {
        final tileRow = ((oy - outY0) * th ~/ (outY1 - outY0)) * tw;
        final outRow = oy * outWidth;
        for (var ox = outX0; ox < outX1; ox++) {
          final s = (tileRow + (ox - outX0) * tw ~/ (outX1 - outX0)) * 4;
          final d = (outRow + ox) * 4;
          output[d] = tile[s];
          output[d + 1] = tile[s + 1];
          output[d + 2] = tile[s + 2];
          output[d + 3] = tile[s + 3];
        }
      }
    }
  }
  return output;
}
