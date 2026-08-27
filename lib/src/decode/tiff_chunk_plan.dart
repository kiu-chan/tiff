import '../image/image_metadata.dart';

/// A plan for decoding a page's [TiffImage.decodeRegionRgba8] in a series of
/// horizontal chunks, computed to avoid two failure modes at once:
///
/// - **Redundant redecoding.** [TiffImage.decodeRegionRgba8] has no
///   cross-call cache — a strip or tile that's taller than one chunk gets
///   independently redecoded once per chunk it overlaps. For a real
///   whole-slide-image file (512px-tall tiles are common), decoding one
///   thin row at a time can mean the same tile gets redecoded 500+ times
///   over the course of a page.
/// - **Unbounded memory.** A page's tile/strip height can be much taller
///   than a caller wants to hold in memory at once — for an extremely wide
///   page, even one full tile row can be hundreds of MB.
///
/// [forBudget] resolves the tension by starting from the page's natural
/// tile/strip height (so every chunk of the underlying compressed data is
/// decoded exactly once) and only shrinking below it if the caller's
/// [TiffChunkPlan.forBudget]'s `maxBytesPerChunk` forces that — the
/// remaining redundancy in that fallback case is the acknowledged cost of
/// keeping memory bounded, not an oversight.
class TiffChunkPlan {
  /// Height in rows of every chunk except possibly the last, which is
  /// shorter if [TiffImageMetadata.height] isn't a multiple of it.
  final int chunkHeight;

  /// The actual raw decode cost of one [chunkHeight]-tall chunk — at most
  /// the `maxBytesPerChunk` [forBudget] was given, but never more (and
  /// often noticeably less, since [chunkHeight] is rounded to a whole
  /// number of tile/strip rows). Pass this to [recommendedWorkerCount]
  /// rather than re-deriving it — the per-pixel cost model behind it is
  /// this package's own internal detail, not meant to be recomputed by a
  /// caller.
  final int bytesPerChunk;

  /// `(y, height)` pairs covering the whole page top to bottom, each ready
  /// to hand straight to `TiffImage.decodeRegionRgba8` (paired with
  /// `x: 0, width: metadata.width`).
  final List<(int y, int height)> chunks;

  const TiffChunkPlan._({required this.chunkHeight, required this.bytesPerChunk, required this.chunks});

  /// Raw per-pixel cost of one `decodeRegionRgba8` call: the intermediate
  /// [TiffRasterBuffer.samples] the decode pipeline produces first (built by
  /// `allocateSampleBuffer` as the narrowest typed-data list [bitsPerSample]
  /// allows — see its doc comment) plus the final RGBA8 conversion (4
  /// bytes/pixel), which is briefly alive alongside it.
  static int _bytesPerPixel(TiffImageMetadata m) => m.samplesPerPixel * _bytesPerSample(m) + 4;

  /// Bytes one raw sample actually costs once unpacked into memory — the
  /// same bucketing `allocateSampleBuffer` uses (1 byte up to 8 bits, 2 up
  /// to 16, 4 above that). Uses the *widest* channel in [TiffImageMetadata
  /// .bitsPerSample] rather than [LayoutCommon.uniformBitsPerSample] — this
  /// is a planning estimate, not a decode, so it deliberately never throws
  /// on a page shape a later decode might reject (differing per-channel
  /// depths, planar configuration); taking the max only ever overestimates
  /// memory use in that case, never underestimates it.
  static int _bytesPerSample(TiffImageMetadata m) {
    if (m.bitsPerSample.isEmpty) return 1;
    var maxBits = 0;
    for (final bits in m.bitsPerSample) {
      if (bits > maxBits) maxBits = bits;
    }
    if (maxBits <= 8) return 1;
    if (maxBits <= 16) return 2;
    return 4;
  }

  /// Plans chunks for [metadata] so that one chunk's raw decode costs no
  /// more than [maxBytesPerChunk] — a budget the caller computes however it
  /// likes (a fixed constant, a fraction of a live memory reading, a
  /// per-device number, ...); this factory does no I/O and reads no
  /// process/OS state of its own.
  ///
  /// [maxBytesPerChunk] is a *soft* ceiling: [chunkHeight] never goes below
  /// [minChunkHeight] (default 1), so an unreasonably small budget still
  /// produces a usable plan rather than one that can't make progress.
  factory TiffChunkPlan.forBudget(
    TiffImageMetadata metadata, {
    required int maxBytesPerChunk,
    int minChunkHeight = 1,
  }) {
    if (maxBytesPerChunk <= 0) {
      throw ArgumentError.value(maxBytesPerChunk, 'maxBytesPerChunk', 'must be > 0');
    }
    if (minChunkHeight <= 0) {
      throw ArgumentError.value(minChunkHeight, 'minChunkHeight', 'must be > 0');
    }

    final naturalChunk = metadata.isTiled
        ? metadata.tileLength!
        : (metadata.rowsPerStrip > 0 ? metadata.rowsPerStrip : metadata.height);
    final bytesPerPixel = _bytesPerPixel(metadata);
    final maxRows = maxBytesPerChunk ~/ (metadata.width * bytesPerPixel);
    final chunkHeight = [
      naturalChunk,
      maxRows,
      metadata.height,
    ].reduce((a, b) => a < b ? a : b).clamp(minChunkHeight, metadata.height);

    return TiffChunkPlan._(
      chunkHeight: chunkHeight,
      bytesPerChunk: chunkHeight * metadata.width * bytesPerPixel,
      chunks: [
        for (var y = 0; y < metadata.height; y += chunkHeight)
          (y, chunkHeight < metadata.height - y ? chunkHeight : metadata.height - y),
      ],
    );
  }

  /// How many chunks of [bytesPerChunk] each (typically a plan's own
  /// [TiffChunkPlan.bytesPerChunk]) can run at once without the aggregate
  /// exceeding [aggregateBudgetBytes] — the number to pass as a parallel
  /// decoder's worker count when chunk size was chosen independently of
  /// worker count (as [forBudget] does; see its doc comment for why
  /// shrinking chunks to fit more workers is usually the wrong trade-off).
  /// Also capped at [cpuCount] (never spawn more workers than there are
  /// cores to run them on) and always at least 1.
  static int recommendedWorkerCount({
    required int bytesPerChunk,
    required int aggregateBudgetBytes,
    required int cpuCount,
  }) {
    final memoryCap = aggregateBudgetBytes ~/ (bytesPerChunk < 1 ? 1 : bytesPerChunk);
    final capped = [memoryCap, cpuCount].reduce((a, b) => a < b ? a : b);
    return capped < 1 ? 1 : capped;
  }
}
