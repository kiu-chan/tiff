import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../raster/color/image_adjustments.dart';
import '../region/tiff_region.dart';
import 'pyramid_source.dart';
import 'viewport_math.dart';

/// One request to a [lodWorkerEntry] isolate: the region [x], [y], [width],
/// [height] of [rung] (a page of the source's pyramid, or [overviewRung] for
/// the overview the worker keeps in memory), assembled from [memberWidth] x
/// [memberHeight] members and box-filtered down to `1 / 2^reduction` of its
/// size. Brightness/contrast/gamma are baked into the returned pixels.
typedef LodWorkerRequest = ({
  int id,
  int rung,
  int x,
  int y,
  int width,
  int height,
  int memberWidth,
  int memberHeight,
  int reduction,
  double brightness,
  double contrast,
  double gamma,
});

/// Asks a [lodWorkerEntry] isolate for [tiles] (tile x, tile y) of [rung]
/// as standalone JPEG streams (see `TiffImage.readTileJpeg`), to be decoded
/// by the platform codec on the main isolate — `dart:ui`'s codecs can't run
/// on a worker isolate.
typedef LodJpegRequest = ({int id, int rung, List<(int, int)> tiles});

/// Entry point for one long-lived decode isolate behind a viewer. It stays
/// alive while the viewer is open, so panning and zooming never pays
/// isolate-spawn cost per tile.
///
/// Handshake: sends its own [SendPort] back first (or a `String` error if
/// the source can't be opened), then answers each [LodWorkerRequest] with
/// `(id, rgba, width, height)` or `(id, error)`, and each [LodJpegRequest]
/// with `(id, jpegs)` — null for a sparse or unreadable tile. A `null`
/// message closes the source and ends the isolate.
void lodWorkerEntry((SendPort, PyramidSourceConfig) args) {
  final (mainSendPort, config) = args;
  final PyramidSource source;
  try {
    config.setUpIsolate?.call();
    source = PyramidSource.open(config);
  } catch (e) {
    mainSendPort.send('$e');
    return;
  }
  final plan = describeRungs([
    for (final rung in source.rungs) rung.metadata,
  ]).overview;
  // Decoded on first use and kept unadjusted, so an adjustment change only
  // re-applies the adjustment — the viewer sends every overview request to
  // the same worker.
  Uint8List? overview;

  final requestPort = ReceivePort();
  mainSendPort.send(requestPort.sendPort);
  requestPort.listen((message) {
    if (message == null) {
      requestPort.close();
      source.close();
      return;
    }
    if (message is LodJpegRequest) {
      final rung = source.rungs[message.rung];
      final jpegs = <Uint8List?>[];
      for (final (tileX, tileY) in message.tiles) {
        try {
          jpegs.add(rung.readTileJpeg(tileX, tileY));
        } catch (_) {
          jpegs.add(null);
        }
      }
      mainSendPort.send((message.id, jpegs));
      return;
    }
    final request = message as LodWorkerRequest;
    try {
      // Decoded up front rather than inside a member load, where
      // assembleRegion would swallow the failure as a transparent member —
      // the viewer must hear that the overview is unusable.
      final overviewPixels = request.rung == overviewRung
          ? overview ??= decodeOverview(source.rungs[plan.rung], plan)
          : null;
      final (rgba, width, height) = assembleRegion(
        request,
        overviewPixels != null
            ? (x, y, width, height) =>
                  cropRgba(overviewPixels, plan.width, x, y, width, height)
            : (x, y, width, height) =>
                  source.rungs[request.rung].decodeRegionRgba8(
                    TiffRegion(x: x, y: y, width: width, height: height),
                  ),
      );
      final adjusted = ImageAdjustments.apply(
        rgba,
        brightness: request.brightness,
        contrast: request.contrast,
        gamma: request.gamma,
      );
      mainSendPort.send((request.id, adjusted, width, height));
    } catch (e) {
      mainSendPort.send((request.id, '$e'));
    }
  });
}

/// The [width] x [height] block at ([x], [y]) of [rgba], an RGBA8 image
/// [sourceWidth] pixels wide, as a new buffer.
Uint8List cropRgba(
  Uint8List rgba,
  int sourceWidth,
  int x,
  int y,
  int width,
  int height,
) {
  final output = Uint8List(width * height * 4);
  for (var row = 0; row < height; row++) {
    final start = ((y + row) * sourceWidth + x) * 4;
    output.setRange(row * width * 4, (row + 1) * width * 4, rgba, start);
  }
  return output;
}

/// Builds [request]'s region as RGBA8 at `1 / 2^reduction` scale, loading one
/// member at a time via [loadMember] — so however many members a composite
/// spans, only one is ever held decoded at once. A member that fails to load
/// is left transparent, letting the viewer's fallback layer show through
/// rather than failing the whole composite.
(Uint8List, int, int) assembleRegion(
  LodWorkerRequest request,
  Uint8List Function(int x, int y, int width, int height) loadMember,
) {
  final shift = request.reduction;
  if (shift == 0 &&
      request.width <= request.memberWidth &&
      request.height <= request.memberHeight) {
    return (
      loadMember(request.x, request.y, request.width, request.height),
      request.width,
      request.height,
    );
  }

  final outWidth = reducedExtent(request.width, shift);
  final outHeight = reducedExtent(request.height, shift);
  final sums = Uint32List(outWidth * outHeight * 4);
  final counts = Uint32List(outWidth * outHeight);
  // Every source pixel is averaged up to an 8x reduction; past that, 8
  // evenly spaced samples per axis already make a clean box filter, far
  // faster — sparser sampling lets fine texture alias into jagged noise.
  final stride = math.max(1, (1 << shift) >> 3);
  final right = request.x + request.width;
  final bottom = request.y + request.height;

  for (var my = request.y; my < bottom; my += request.memberHeight) {
    final memberHeight = math.min(request.memberHeight, bottom - my);
    for (var mx = request.x; mx < right; mx += request.memberWidth) {
      final memberWidth = math.min(request.memberWidth, right - mx);
      final Uint8List member;
      try {
        member = loadMember(mx, my, memberWidth, memberHeight);
      } catch (_) {
        continue;
      }
      // Sample on a grid aligned to the region rather than to each member,
      // so neighboring members contribute evenly to a shared output pixel.
      final firstSy = (stride - (my - request.y) % stride) % stride;
      final firstSx = (stride - (mx - request.x) % stride) % stride;
      for (var sy = firstSy; sy < memberHeight; sy += stride) {
        final outRow = ((my - request.y + sy) >> shift) * outWidth;
        final srcRow = sy * memberWidth;
        for (var sx = firstSx; sx < memberWidth; sx += stride) {
          final o = outRow + ((mx - request.x + sx) >> shift);
          final s = (srcRow + sx) * 4;
          final o4 = o * 4;
          sums[o4] += member[s];
          sums[o4 + 1] += member[s + 1];
          sums[o4 + 2] += member[s + 2];
          sums[o4 + 3] += member[s + 3];
          counts[o]++;
        }
      }
    }
  }

  final output = Uint8List(outWidth * outHeight * 4);
  for (var o = 0; o < counts.length; o++) {
    final n = counts[o];
    if (n == 0) continue;
    final half = n >> 1;
    final o4 = o * 4;
    output[o4] = (sums[o4] + half) ~/ n;
    output[o4 + 1] = (sums[o4 + 1] + half) ~/ n;
    output[o4 + 2] = (sums[o4 + 2] + half) ~/ n;
    output[o4 + 3] = (sums[o4 + 3] + half) ~/ n;
  }
  return (output, outWidth, outHeight);
}
