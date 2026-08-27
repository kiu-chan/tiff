import 'dart:io';
import 'dart:math' as math;

import '../decode/tiff_chunk_plan.dart';
import '../image/image_metadata.dart';
import 'system_memory_info.dart';

/// Picks a `(maxBytesPerChunk, workerCount)` pair for
/// [TiffParallelDecoder.decodeBanded] sized to both [metadata] *and* the
/// machine actually running it — the pairing [TiffChunkPlan] and
/// [TiffChunkPlan.recommendedWorkerCount] need a caller to already know
/// (see their own doc comments on why neither reads OS/CPU state itself).
/// Without this, a caller either hardcodes a number that's far too small
/// for a big multi-core machine with memory to spare, or far too large for
/// a small one — [recommend] instead reads what's actually idle right now
/// ([SystemMemoryInfo.probe], [Platform.numberOfProcessors]) and sizes to
/// that, per call, so the same code adapts to whatever machine it runs on
/// and however loaded it is at the time.
class TiffAutoDecodeBudget {
  const TiffAutoDecodeBudget._();

  /// Recommends chunk/worker sizing for decoding [metadata] in parallel.
  ///
  /// [SystemMemoryInfo.availableBytes] ("free + reclaimable") is a snapshot
  /// taken once, before decoding starts — it is *not* a promise that memory
  /// stays free for as long as the decode runs, since other processes on a
  /// real, shared machine keep allocating the whole time. Two margins are
  /// subtracted from it before any of that snapshot is actually spent:
  ///
  /// - [reserveFraction] (of [SystemMemoryInfo.totalBytes]) /
  ///   [reserveBytes], whichever is larger — memory left untouched for the
  ///   rest of the machine (other apps, the OS itself), since "available"
  ///   read once at the start can look far roomier than it stays a minute
  ///   into a multi-minute decode.
  /// - [doubleBufferSafetyFactor] — [TiffParallelDecoder]'s per-worker loop
  ///   decodes chunks one after another on the *same* isolate; there's no
  ///   guarantee the previous chunk's buffer is actually collected before
  ///   the next one is allocated, so real peak usage can briefly run above
  ///   the "one chunk per worker" figure this budget is otherwise sized
  ///   from. Dividing by this factor (instead of assuming perfectly prompt
  ///   GC) is what keeps that transient overlap inside the ceiling too.
  ///
  /// What's left after those two margins is what [systemMemoryFraction]
  /// actually applies to — the default (0.55) leans on those two margins
  /// having already come off first rather than being conservative on top of
  /// them too, since a chunk shrunk well below its source's native
  /// tile/strip height (see the note on `maxBytesPerChunk` below) doesn't
  /// just use less memory, it makes the whole decode redundantly re-read
  /// the same tile/strip data more times as the shortfall grows; a caller
  /// certain it has the machine entirely to itself can still push this
  /// higher.
  ///
  /// - [reservedCores]: cores left idle for whatever else is running (the
  ///   caller's own UI thread, other apps) rather than handed to decode
  ///   workers. Default 1.
  /// - [fallbackAggregateBytes]/[minAggregateBytes]/[maxAggregateBytes]:
  ///   [fallbackAggregateBytes] is used verbatim when [SystemMemoryInfo.probe]
  ///   returns `null` (mobile, or any probe failure — see its doc comment)
  ///   — the same fixed, conservative budget a caller would otherwise have
  ///   had to hardcode themselves. [minAggregateBytes]/[maxAggregateBytes]
  ///   bound the computed figure either way, the latter so a huge-RAM
  ///   machine still doesn't hand one one-off decode an unreasonable slice
  ///   of it.
  /// - [minBytesPerChunk]: floor on the per-chunk figure below, so an
  ///   unusually high [Platform.numberOfProcessors] on a memory-constrained
  ///   machine can't divide the budget into chunks too thin to be worth the
  ///   redundant-redecode cost each one adds (see below).
  ///
  /// The returned `maxBytesPerChunk` is the *aggregate* budget divided
  /// across up to `cpuCount` concurrent chunks — deliberately not the whole
  /// aggregate handed to one chunk the way a caller might otherwise read
  /// [TiffParallelDecoder.decodeBanded]'s own doc comment (which frames
  /// `maxBytesPerChunk` as one worker's own cap, picked independently of
  /// worker count, precisely to keep chunks tile-aligned). That framing
  /// optimizes for zero redundant redecode at the cost of collapsing to a
  /// single worker whenever the budget can't fit more than one full
  /// tile/strip-aligned chunk at once — exactly the case a memory-
  /// constrained machine with idle CPU cores hits, and idle cores are
  /// wasted for no memory saved (worker count was never what capped memory
  /// in that case — chunk size was). Dividing first means: when the budget
  /// already fits `cpuCount` full tile-aligned chunks, this has no effect
  /// ([TiffChunkPlan.forBudget] caps chunk height at the native tile/strip
  /// height regardless of how much bigger the per-chunk cap is, so nothing
  /// shrinks); only when it doesn't does this shrink chunks below that
  /// native height, trading some redundant redecoding of the same
  /// tile/strip (once per chunk that overlaps it) for spreading that
  /// redundant work across otherwise-idle cores *concurrently* instead of
  /// paying for it serially on one core — net faster wall-clock time within
  /// the exact same memory ceiling as before, not more.
  static ({int maxBytesPerChunk, int workerCount}) recommend(
    TiffImageMetadata metadata, {
    double systemMemoryFraction = 0.55,
    double reserveFraction = 0.12,
    int reserveBytes = 768 * 1024 * 1024,
    double doubleBufferSafetyFactor = 1.5,
    int reservedCores = 1,
    int fallbackAggregateBytes = 512 * 1024 * 1024,
    int minAggregateBytes = 64 * 1024 * 1024,
    int maxAggregateBytes = 6144 * 1024 * 1024,
    int minBytesPerChunk = 16 * 1024 * 1024,
  }) {
    final mem = SystemMemoryInfo.probe();
    final int rawAggregateBytes;
    if (mem == null) {
      rawAggregateBytes = fallbackAggregateBytes;
    } else {
      final reserve = math.max(reserveBytes, (mem.totalBytes * reserveFraction).round());
      final usable = math.max(0, mem.availableBytes - reserve);
      rawAggregateBytes = (usable * systemMemoryFraction / doubleBufferSafetyFactor).round();
    }
    final aggregateBudgetBytes = rawAggregateBytes.clamp(minAggregateBytes, maxAggregateBytes);
    final cpuCount = math.max(1, Platform.numberOfProcessors - reservedCores);

    final perChunkBudgetBytes = math.max(minBytesPerChunk, aggregateBudgetBytes ~/ cpuCount);
    final chunkPlan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: perChunkBudgetBytes);
    final workerCount = TiffChunkPlan.recommendedWorkerCount(
      bytesPerChunk: chunkPlan.bytesPerChunk,
      aggregateBudgetBytes: aggregateBudgetBytes,
      cpuCount: cpuCount,
    );
    return (maxBytesPerChunk: perChunkBudgetBytes, workerCount: workerCount);
  }
}
