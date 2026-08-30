import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../decode/tiff_chunk_plan.dart';
import '../region/tiff_region.dart';
import '../tiff_decoder.dart';
import '../tiff_exception.dart';
import 'file_byte_source.dart';

/// One band of already-decoded RGBA8 pixels, delivered by
/// [TiffParallelDecoder.decodeBanded].
typedef TiffBand = ({int y, int height, Uint8List rgba});

/// Message shape sent to each worker isolate spawned by
/// [TiffParallelDecoder.decodeBanded] — a plain positional record (rather
/// than a custom class) since that's what crosses an isolate boundary
/// cleanly. [setUpIsolate] must be a static or top-level function reference
/// (a closure over local state can't cross the boundary at all).
typedef _WorkerArgs = (
  SendPort,
  String filePath,
  int pageIndex,
  int width,
  int bandHeight,
  List<(int, int)> chunks,
  void Function()? setUpIsolate,
);

/// Decodes a TIFF/BigTIFF page in horizontal bands across a pool of
/// isolates — the parallel counterpart to [TiffImage.decodeRegionRgba8]'s
/// single-call, single-core decode, for a page too large to want to decode
/// serially. Every knob here (band height, chunk memory budget, worker
/// count) is an explicit parameter the caller supplies — this class reads
/// no process/OS memory state of its own and makes no assumption about how
/// many CPU cores are safe to use; that judgment belongs to the caller,
/// which is in a much better position to know what else is competing for
/// the same machine's memory and cores.
class TiffParallelDecoder {
  const TiffParallelDecoder._();

  /// Decodes page [pageIndex] of the file at [filePath] in horizontal
  /// bands, spread across up to [workerCount] isolates — each opens its own
  /// handle on [filePath] (a decoded `TiffImage` and its underlying file
  /// handle can't cross an isolate boundary, so there's no way to share one
  /// already-open document across workers). [onBand] is called back on the
  /// *caller's* isolate once per decoded band, so it can do arbitrary work
  /// per band — write a file, accumulate into a buffer, feed a progress
  /// counter — without that work itself needing to be isolate-safe. Bands
  /// from different workers can interleave, so don't assume they arrive in
  /// increasing [TiffBand.y] order across the whole page (they do arrive in
  /// order within any one worker's own share of it).
  ///
  /// [bandHeight] is the height of each delivered [TiffBand] — independent
  /// of the taller, tile/strip-aligned chunk actually decoded per call (see
  /// [TiffChunkPlan]); one chunk decode gets sliced into [bandHeight]-tall
  /// pieces before delivery, so a caller that wants a tight per-band memory
  /// footprint doesn't have to give up the tile-alignment that avoids
  /// redundant redecoding.
  ///
  /// [maxBytesPerChunk] bounds one worker's one in-flight chunk decode (see
  /// [TiffChunkPlan.forBudget]) — it is *not* divided by [workerCount]
  /// here, since up to [workerCount] chunks can be in flight at once. If
  /// you need the aggregate peak (`workerCount * maxBytesPerChunk`, roughly)
  /// bounded by some total budget, pick [workerCount] via
  /// [TiffChunkPlan.recommendedWorkerCount] against that budget and this
  /// same [maxBytesPerChunk] — deliberately not done automatically here,
  /// since shrinking [maxBytesPerChunk] to fit more workers instead
  /// reintroduces the redundant-redecode problem [TiffChunkPlan] exists to
  /// avoid (see its doc comment).
  ///
  /// If the source uses a codec that needs a plugged-in decoder (JPEG,
  /// Compression 6/7 — see `package:tiff/tiff_image_adapter.dart`), pass
  /// [setUpIsolate] as a **static or top-level function reference** (not a
  /// closure capturing local state, which can't cross an isolate boundary)
  /// that wires it up — e.g. `TiffImageAdapter.enableJpegSupport` — called
  /// once in every worker isolate before that worker decodes anything.
  ///
  /// Throws a [TiffException] (wrapping whatever error message a worker
  /// reported) if any worker's decode fails; the remaining workers are
  /// killed rather than left to keep running.
  static Future<void> decodeBanded({
    required String filePath,
    required int pageIndex,
    required int bandHeight,
    required int maxBytesPerChunk,
    required int workerCount,
    required void Function(TiffBand band) onBand,
    void Function()? setUpIsolate,
  }) async {
    if (bandHeight <= 0) {
      throw ArgumentError.value(bandHeight, 'bandHeight', 'must be > 0');
    }
    if (workerCount <= 0) {
      throw ArgumentError.value(workerCount, 'workerCount', 'must be > 0');
    }

    final metadataSource = FileByteSource.open(File(filePath));
    final int width;
    final List<(int, int)> chunks;
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
      width = metadata.width;
      chunks = TiffChunkPlan.forBudget(
        metadata,
        maxBytesPerChunk: maxBytesPerChunk,
      ).chunks;
    } finally {
      metadataSource.close();
    }
    if (chunks.isEmpty) return;

    final effectiveWorkerCount = workerCount < chunks.length
        ? workerCount
        : chunks.length;
    final chunksByWorker = List.generate(
      effectiveWorkerCount,
      (_) => <(int, int)>[],
    );
    for (var i = 0; i < chunks.length; i++) {
      chunksByWorker[i % effectiveWorkerCount].add(chunks[i]);
    }

    final receivePort = ReceivePort();
    final isolates = <Isolate>[];
    String? workerError;
    try {
      for (final assigned in chunksByWorker) {
        isolates.add(
          await Isolate.spawn(_bandWorkerEntry, (
            receivePort.sendPort,
            filePath,
            pageIndex,
            width,
            bandHeight,
            assigned,
            setUpIsolate,
          )),
        );
      }

      var finishedWorkers = 0;
      await for (final message in receivePort) {
        if (message is (int, int, Uint8List)) {
          final (y, height, rgba) = message;
          onBand((y: y, height: height, rgba: rgba));
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
  }
}

void _bandWorkerEntry(_WorkerArgs args) {
  final (
    mainSendPort,
    filePath,
    pageIndex,
    width,
    bandHeight,
    chunks,
    setUpIsolate,
  ) = args;
  try {
    setUpIsolate?.call();
    final document = TiffDecoder.decodeSource(
      FileByteSource.open(File(filePath)),
    );
    try {
      final page = document.images[pageIndex];
      final bytesPerRow = width * 4;
      for (final (y, chunkHeight) in chunks) {
        final chunkRgba = page.decodeRegionRgba8(
          TiffRegion(x: 0, y: y, width: width, height: chunkHeight),
        );

        var rowOffset = 0;
        while (rowOffset < chunkHeight) {
          final remaining = chunkHeight - rowOffset;
          final rows = bandHeight < remaining ? bandHeight : remaining;
          final band = Uint8List.sublistView(
            chunkRgba,
            rowOffset * bytesPerRow,
            (rowOffset + rows) * bytesPerRow,
          );
          mainSendPort.send((y + rowOffset, rows, band));
          rowOffset += rows;
        }
      }
      mainSendPort.send(true);
    } finally {
      document.close();
    }
  } catch (e) {
    mainSendPort.send('$e');
  }
}
