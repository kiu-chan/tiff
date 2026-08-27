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
  /// actually applies to — the default (0.4) is deliberately modest given
  /// how much margin already came off above; a caller certain it has the
  /// machine entirely to itself can still push this higher.
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
  ///
  /// The returned `maxBytesPerChunk` is deliberately an *aggregate* figure
  /// (the same value [TiffChunkPlan.forBudget] and
  /// [TiffChunkPlan.recommendedWorkerCount] are both given) rather than
  /// divided by `workerCount` — see [TiffParallelDecoder.decodeBanded]'s
  /// doc comment for why dividing it would shrink chunks below the
  /// source's native tile/strip height and reintroduce redundant redecoding.
  static ({int maxBytesPerChunk, int workerCount}) recommend(
    TiffImageMetadata metadata, {
    double systemMemoryFraction = 0.4,
    double reserveFraction = 0.15,
    int reserveBytes = 512 * 1024 * 1024,
    double doubleBufferSafetyFactor = 1.5,
    int reservedCores = 1,
    int fallbackAggregateBytes = 512 * 1024 * 1024,
    int minAggregateBytes = 64 * 1024 * 1024,
    int maxAggregateBytes = 4096 * 1024 * 1024,
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

    final chunkPlan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: aggregateBudgetBytes);
    final workerCount = TiffChunkPlan.recommendedWorkerCount(
      bytesPerChunk: chunkPlan.bytesPerChunk,
      aggregateBudgetBytes: aggregateBudgetBytes,
      cpuCount: cpuCount,
    );
    return (maxBytesPerChunk: aggregateBudgetBytes, workerCount: workerCount);
  }
}
