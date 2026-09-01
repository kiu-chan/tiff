import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../image/tiff_image.dart';
import '../io/file_byte_source.dart';
import '../io/tiff_auto_decode_budget.dart';
import '../region/tiff_region.dart';
import '../tiff_decoder.dart';
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
  ///
  /// [onBand], if given, is called once per band as it finishes decoding
  /// and folding into [dst] — `bandIndex`/`bandCount` (both 1-based) locate
  /// it among the total bands this call will need, `bandSrcRows` is how
  /// many source rows that band covered (the actual per-band unit of work,
  /// since a tight [maxBandBytes] can make bands cover very different row
  /// counts near a source's edges).
  static Uint8List downsample(
    TiffImage page, {
    required int dstWidth,
    required int dstHeight,
    int maxBandBytes = 128 * 1024 * 1024,
    void Function(int bandIndex, int bandCount, int bandSrcRows)? onBand,
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
      final rgba = page.decodeRegionRgba8(
        TiffRegion(x: 0, y: 0, width: srcWidth, height: srcHeight),
      );
      dst.setAll(0, rgba);
      onBand?.call(1, 1, srcHeight);
      return dst;
    }

    final bytesPerSrcRow = srcWidth * 4;
    final maxRowsPerBand = math.max(1, maxBandBytes ~/ bytesPerSrcRow);

    // Precomputed once — every output row's source column span never
    // changes band to band, only its row span does.
    final sx0 = List<int>.generate(
      dstWidth,
      (ox) => _spanStart(ox, dstWidth, srcWidth),
    );
    final sx1 = List<int>.generate(
      dstWidth,
      (ox) => _spanEnd(ox, dstWidth, srcWidth, sx0[ox]),
    );

    // Planned upfront (cheap — arithmetic only, no decoding) so onBand can
    // report a real "band N of M" figure from the very first callback,
    // rather than a total that only becomes known once the last band has
    // already been decoded.
    final plan = _planBands(dstHeight, srcHeight, maxRowsPerBand);

    for (var b = 0; b < plan.length; b++) {
      final (oy, oyEnd, bandSyStart, bandSyEnd) = plan[b];
      final band = page.decodeRegionRgba8(
        TiffRegion(
          x: 0,
          y: bandSyStart,
          width: srcWidth,
          height: bandSyEnd - bandSyStart,
        ),
      );
      _foldBand(
        band: band,
        oy: oy,
        oyEnd: oyEnd,
        bandSyStart: bandSyStart,
        bandSyEnd: bandSyEnd,
        srcWidth: srcWidth,
        srcHeight: srcHeight,
        dstWidth: dstWidth,
        dstHeight: dstHeight,
        sx0: sx0,
        sx1: sx1,
        dst: dst,
      );
      onBand?.call(b + 1, plan.length, bandSyEnd - bandSyStart);
    }
    return dst;
  }

  /// The same box-average [downsample] computes, but decoding every planned
  /// band across up to [workerCount] isolates instead of one at a time on
  /// the caller's own — real multi-core parallelism for the (often
  /// dominant) decode cost of a huge source's first pyramid rung, not just
  /// the bounded-memory banding [downsample] already provides. Bit-for-bit
  /// identical output to [downsample] given the same [maxBandBytes] (band
  /// boundaries are planned identically; only *which isolate* decodes each
  /// one, and in what order they arrive back, differs) — each planned band
  /// still gets exactly one whole [TiffImage.decodeRegionRgba8] call, still
  /// folded into non-overlapping output rows of [dst], so which worker
  /// handles it or when its result arrives back never changes what's
  /// computed, only how long it takes.
  ///
  /// Unlike [downsample], this can't take an already-open [TiffImage] —
  /// each worker isolate opens its own handle on [filePath] independently
  /// (a decoded `TiffImage` and its file handle can't cross an isolate
  /// boundary), the same reason [TiffParallelDecoder.decodeBanded] takes a
  /// path rather than a `TiffImage` too. [pageIndex] picks which page of
  /// [filePath] to decode (0 for the common single/first-page case).
  ///
  /// [onBand]'s `bandIndex` still counts up from 1 to `bandCount` as before,
  /// but no longer corresponds to *planned* band order — bands from
  /// different workers can complete in any order, so it only ever means
  /// "how many of the total are done so far", not "which specific one".
  ///
  /// [maxBandBytes] and [workerCount] are both optional — leave either (or
  /// both) unset to have [TiffAutoDecodeBudget.recommend] pick it from
  /// actual idle system memory and CPU count, the same way
  /// [TiffParallelDecoder.decodeBanded] does when left to its own defaults.
  /// Pass either explicitly to override just that one; the other still
  /// comes from the same recommended budget unless it's overridden too, so
  /// a caller that only wants to cap worker count (say, to leave a core
  /// free for the rest of the app) doesn't have to also work out a matching
  /// per-band byte budget by hand.
  ///
  /// [setUpIsolate], if given, must be a **static or top-level function
  /// reference** (not a closure over local state, which can't cross an
  /// isolate boundary) — e.g. `TiffImageAdapter.enableJpegSupport`, needed
  /// in every worker before it can decode a JPEG-compressed source.
  static Future<Uint8List> downsampleParallel({
    required String filePath,
    required int dstWidth,
    required int dstHeight,
    int pageIndex = 0,
    int? maxBandBytes,
    int? workerCount,
    void Function()? setUpIsolate,
    void Function(int bandIndex, int bandCount, int bandSrcRows)? onBand,
  }) async {
    if (dstWidth <= 0 || dstHeight <= 0) {
      throw ArgumentError('dstWidth and dstHeight must be > 0');
    }
    if (maxBandBytes != null && maxBandBytes <= 0) {
      throw ArgumentError.value(maxBandBytes, 'maxBandBytes', 'must be > 0');
    }
    if (workerCount != null && workerCount <= 0) {
      throw ArgumentError.value(workerCount, 'workerCount', 'must be > 0');
    }

    final metadataSource = FileByteSource.open(File(filePath));
    final int srcWidth;
    final int srcHeight;
    final int resolvedMaxBandBytes;
    final int resolvedWorkerCount;
    try {
      final document = TiffDecoder.decodeSource(metadataSource);
      if (pageIndex < 0 || pageIndex >= document.images.length) {
        throw ArgumentError.value(
          pageIndex,
          'pageIndex',
          'out of range (page count: ${document.images.length})',
        );
      }
      final metadata = document.images[pageIndex].metadata;
      srcWidth = metadata.width;
      srcHeight = metadata.height;
      if (maxBandBytes == null || workerCount == null) {
        final budget = TiffAutoDecodeBudget.recommend(metadata);
        resolvedMaxBandBytes = maxBandBytes ?? budget.maxBytesPerChunk;
        resolvedWorkerCount = workerCount ?? budget.workerCount;
      } else {
        resolvedMaxBandBytes = maxBandBytes;
        resolvedWorkerCount = workerCount;
      }
    } finally {
      metadataSource.close();
    }
    if (dstWidth > srcWidth || dstHeight > srcHeight) {
      throw ArgumentError(
        'downsample only shrinks an image — requested ${dstWidth}x$dstHeight '
        'from a ${srcWidth}x$srcHeight source',
      );
    }

    final dst = Uint8List(dstWidth * dstHeight * 4);
    if (dstWidth == srcWidth && dstHeight == srcHeight) {
      // No smaller-than-source rung to spread across workers — one plain
      // decode beats the overhead of spawning any isolate for it.
      final document = TiffDecoder.decodeSource(
        FileByteSource.open(File(filePath)),
      );
      try {
        final rgba = document.images[pageIndex].decodeRegionRgba8(
          TiffRegion(x: 0, y: 0, width: srcWidth, height: srcHeight),
        );
        dst.setAll(0, rgba);
        onBand?.call(1, 1, srcHeight);
        return dst;
      } finally {
        document.close();
      }
    }

    final bytesPerSrcRow = srcWidth * 4;
    final maxRowsPerBand = math.max(1, resolvedMaxBandBytes ~/ bytesPerSrcRow);
    final sx0 = List<int>.generate(
      dstWidth,
      (ox) => _spanStart(ox, dstWidth, srcWidth),
    );
    final sx1 = List<int>.generate(
      dstWidth,
      (ox) => _spanEnd(ox, dstWidth, srcWidth, sx0[ox]),
    );
    final plan = _planBands(dstHeight, srcHeight, maxRowsPerBand);

    final effectiveWorkerCount = resolvedWorkerCount < plan.length
        ? resolvedWorkerCount
        : plan.length;
    final bandsByWorker = List.generate(effectiveWorkerCount, (_) => <int>[]);
    for (var i = 0; i < plan.length; i++) {
      bandsByWorker[i % effectiveWorkerCount].add(i);
    }

    final receivePort = ReceivePort();
    final isolates = <Isolate>[];
    String? workerError;
    var completedBands = 0;
    try {
      for (final planIndices in bandsByWorker) {
        final assigned = [
          for (final i in planIndices) (i, plan[i].$3, plan[i].$4 - plan[i].$3),
        ];
        isolates.add(
          await Isolate.spawn(_bandDecodeWorkerEntry, (
            receivePort.sendPort,
            filePath,
            pageIndex,
            srcWidth,
            assigned,
            setUpIsolate,
          )),
        );
      }

      var finishedWorkers = 0;
      await for (final message in receivePort) {
        if (message is (int, Uint8List)) {
          final (planIndex, band) = message;
          final (oy, oyEnd, bandSyStart, bandSyEnd) = plan[planIndex];
          _foldBand(
            band: band,
            oy: oy,
            oyEnd: oyEnd,
            bandSyStart: bandSyStart,
            bandSyEnd: bandSyEnd,
            srcWidth: srcWidth,
            srcHeight: srcHeight,
            dstWidth: dstWidth,
            dstHeight: dstHeight,
            sx0: sx0,
            sx1: sx1,
            dst: dst,
          );
          completedBands++;
          onBand?.call(completedBands, plan.length, bandSyEnd - bandSyStart);
        } else if (message == true) {
          finishedWorkers++;
          if (finishedWorkers == effectiveWorkerCount) break;
        } else {
          workerError = message as String;
          break;
        }
      }
    } finally {
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
      receivePort.close();
    }
    if (workerError != null) throw TiffException(workerError);
    return dst;
  }

  /// Box-filters one already-decoded [band] (covering source rows
  /// `[bandSyStart, bandSyEnd)`) into output rows `[oy, oyEnd)` of [dst] —
  /// the inner loop [downsample] and [downsampleParallel] both share, since
  /// which isolate produced [band] (or when) makes no difference to this
  /// math: every output pixel still averages exactly the same source pixel
  /// span, whichever call planned it.
  static void _foldBand({
    required Uint8List band,
    required int oy,
    required int oyEnd,
    required int bandSyStart,
    required int bandSyEnd,
    required int srcWidth,
    required int srcHeight,
    required int dstWidth,
    required int dstHeight,
    required List<int> sx0,
    required List<int> sx1,
    required Uint8List dst,
  }) {
    if (band.length != (bandSyEnd - bandSyStart) * srcWidth * 4) {
      throw TiffException(
        'decodeRegionRgba8 returned an unexpected byte count for a banded downsample',
      );
    }
    for (var y = oy; y < oyEnd; y++) {
      final ySpanStart = _spanStart(y, dstHeight, srcHeight);
      final sy0 = ySpanStart - bandSyStart;
      final sy1 = _spanEnd(y, dstHeight, srcHeight, ySpanStart) - bandSyStart;
      for (var ox = 0; ox < dstWidth; ox++) {
        var r = 0, g = 0, b2 = 0, a = 0, count = 0;
        for (var sy = sy0; sy < sy1; sy++) {
          var i = (sy * srcWidth + sx0[ox]) * 4;
          for (var sx = sx0[ox]; sx < sx1[ox]; sx++) {
            r += band[i];
            g += band[i + 1];
            b2 += band[i + 2];
            a += band[i + 3];
            count++;
            i += 4;
          }
        }
        // Integer round-half-up (`(2*sum + count) ~/ (2*count)`) instead
        // of `(sum / count).round()` — same result for every non-negative
        // sum/count (see ImageResampler.downsampleRgba8's 2x fast path,
        // which relies on the same identity), without a double division
        // and round per channel per pixel.
        final o = (y * dstWidth + ox) * 4;
        final count2 = count * 2;
        dst[o] = (2 * r + count) ~/ count2;
        dst[o + 1] = (2 * g + count) ~/ count2;
        dst[o + 2] = (2 * b2 + count) ~/ count2;
        dst[o + 3] = (2 * a + count) ~/ count2;
      }
    }
  }

  /// Groups output rows `0..dstHeight` into row bands, each covering as many
  /// source rows as fit under [maxRowsPerBand] — same growth rule the old
  /// inline loop used, just computed as a list upfront so [downsample] knows
  /// the total band count (for [onBand]) before decoding the first one.
  /// Each tuple is `(oy, oyEnd, bandSyStart, bandSyEnd)`: the output-row
  /// range this band covers, and the source-row range to decode for it.
  static List<(int, int, int, int)> _planBands(
    int dstHeight,
    int srcHeight,
    int maxRowsPerBand,
  ) {
    final plan = <(int, int, int, int)>[];
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
        final candidateEnd = _spanEnd(
          oyEnd,
          dstHeight,
          srcHeight,
          _spanStart(oyEnd, dstHeight, srcHeight),
        );
        if (oyEnd > oy && candidateEnd - bandSyStart > maxRowsPerBand) break;
        bandSyEnd = candidateEnd;
        oyEnd++;
      }
      plan.add((oy, oyEnd, bandSyStart, bandSyEnd));
      oy = oyEnd;
    }
    return plan;
  }

  /// The inclusive start of the source span output pixel [out] (out of
  /// [dstExtent] total) covers along one axis of [srcExtent].
  static int _spanStart(int out, int dstExtent, int srcExtent) =>
      (out * srcExtent) ~/ dstExtent;

  /// The exclusive end of that same span — identical formula to
  /// [ImageResampler.downsampleRgba8]'s own `_spanEnd`, kept in lockstep so
  /// this produces the same output a whole-buffer call would.
  static int _spanEnd(int out, int dstExtent, int srcExtent, int start) {
    final end = ((out + 1) * srcExtent) ~/ dstExtent;
    return (out == dstExtent - 1 ? srcExtent : end).clamp(start + 1, srcExtent);
  }
}

/// Message shape sent to each worker isolate spawned by
/// [BandedDownsampler.downsampleParallel] — a plain positional record
/// (rather than a custom class) since that's what crosses an isolate
/// boundary cleanly. `assigned` is this worker's share of planned bands, as
/// `(planIndex, sourceRowStart, sourceRowCount)` triples. [setUpIsolate]
/// must be a static or top-level function reference (a closure over local
/// state can't cross the boundary at all).
typedef _ParallelWorkerArgs = (
  SendPort,
  String filePath,
  int pageIndex,
  int srcWidth,
  List<(int, int, int)> assigned,
  void Function()? setUpIsolate,
);

/// Entry point for each worker isolate [BandedDownsampler.downsampleParallel]
/// spawns: opens its own handle on `filePath` (a decoded [TiffImage] can't
/// cross an isolate boundary, so there's no way to share the caller's own
/// already-open one), decodes every band in `assigned` via
/// [TiffImage.decodeRegionRgba8], and sends each one back as
/// `(planIndex, Uint8List)` as soon as it's ready — not batched, so the
/// caller can start folding a band into its output the moment any worker
/// finishes one, rather than waiting on this worker's *entire* share.
/// Sends a final `true` on success or a `String` on failure.
void _bandDecodeWorkerEntry(_ParallelWorkerArgs args) {
  final (sendPort, filePath, pageIndex, srcWidth, assigned, setUpIsolate) =
      args;
  try {
    setUpIsolate?.call();
    final document = TiffDecoder.decodeSource(
      FileByteSource.open(File(filePath)),
    );
    try {
      final page = document.images[pageIndex];
      for (final (planIndex, y, height) in assigned) {
        final band = page.decodeRegionRgba8(
          TiffRegion(x: 0, y: y, width: srcWidth, height: height),
        );
        sendPort.send((planIndex, band));
      }
      sendPort.send(true);
    } finally {
      document.close();
    }
  } catch (e) {
    sendPort.send('$e');
  }
}
