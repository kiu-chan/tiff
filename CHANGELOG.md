## 0.4.0

- `TiffDisplayOptimizer.optimize`'s new `TiffOptimizationMode.pyramidLevelsOnly`
  builds the same progressively-halved, tiled rungs as `tiledPyramid`, but
  without re-encoding the base resolution itself — the output holds only the
  smaller rungs, a small fraction of what `tiledPyramid` writes, since the
  (by far largest) base-resolution copy is never duplicated. Meant for a
  caller that wants extra zoom-out levels as a disposable, sidecar cache
  next to a source that already serves its own base resolution well (e.g.
  it's already tiled), rather than a full standalone replacement file for
  it. Throws `ArgumentError` if the page's longest side is already at or
  below `minPyramidDimension`, since there'd be nothing smaller to build.
- New `TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels` builds the same
  output as `pyramidLevelsOnly`, but for a source too large to safely decode
  as one whole RGBA8 buffer — `optimize` always decodes the whole page
  first regardless of mode, which for a real multi-gigapixel page can
  itself be too large to hold in memory before any downsampling even
  starts. This instead derives the first rung at or below
  `maxDirectDecodePixels` via the new `BandedDownsampler`, which decodes the
  source in row bands (bounded by `maxBandBytes`) rather than all at once —
  bit-for-bit equivalent to what `ImageResampler.downsampleRgba8` would
  produce given the whole source at once, just computed in bounded memory.
  Every rung after that first one reuses the same in-memory halving
  `optimize` itself uses, since each is smaller than the last and therefore
  safe by construction. A rung above `maxDirectDecodePixels` is never
  produced at all (not even via banding) — this exists to help only the far
  zoomed-out end a viewer's own bounded-memory region/tile decode of the
  source doesn't serve well.

## 0.3.0

- Decoded, unpacked samples (`TiffRasterBuffer.samples`, and the equivalent
  intermediate buffer in `ChunkDecoder.decodeChunk`/`PixelUnpacker.unpackRow`)
  are now backed by `Uint8List`/`Uint16List`/`Uint32List` (picked by
  `bitsPerSample` via the new `allocateSampleBuffer`) instead of a generic
  `List<int>`, which costs a full 8-byte machine word per element in Dart
  regardless of how few bits the value actually needs. For the common case —
  8-bit samples, e.g. any RGB whole-slide-image scanner file — this is a
  4x memory reduction per decoded chunk (7 bytes/pixel instead of 28 for
  3-channel RGB, once the final RGBA8 conversion buffer is counted too).
  `TiffChunkPlan`'s own per-pixel cost estimate is updated to match, so a
  memory budget computed from it (directly, or via the `TiffAutoDecodeBudget`
  below) now reflects what a decode actually allocates — previously the
  inflated estimate could force chunks well below a page's native tile/strip
  height purely because of how the intermediate buffer happened to be
  represented, not how much data it actually held, which is exactly what
  forces redundant redecoding (see 0.2.0's note on `TiffChunkPlan.forBudget`)
  and collapses `TiffChunkPlan.recommendedWorkerCount` to a single worker.
  `samples`'s type stays `List<int>` (the public field/`sampleAt` API is
  unchanged) — only what backs it changed.
- `TiffAutoDecodeBudget.recommend` (`package:tiff/tiff_io.dart`) picks a
  `(maxBytesPerChunk, workerCount)` pair for `TiffParallelDecoder.decodeBanded`
  sized to both a page's metadata and the machine actually running it, so a
  caller no longer has to hardcode a number that's either too small for a big,
  idle multi-core machine or too large for a small/mobile one —
  `TiffChunkPlan`/`TiffChunkPlan.recommendedWorkerCount` need a caller to
  already know both by design (see 0.2.0's note on why neither reads OS/CPU
  state itself). Backed by the new `SystemMemoryInfo.probe()` (a best-effort
  system memory reading via `sysctl`/`vm_stat` on macOS, `/proc/meminfo` on
  Linux, or `wmic` on Windows — `null` on mobile, or any probe failure, since
  none of those expose system-wide memory to an app) and
  `Platform.numberOfProcessors`.
  That memory reading is a one-time snapshot, not a promise it stays free for
  the whole decode — a real machine keeps allocating elsewhere the entire
  time a large decode runs — so `recommend` deliberately spends less than the
  snapshot reports available: a reserve (`reserveFraction`/`reserveBytes`,
  whichever is larger) is set aside for the rest of the machine up front, and
  what's left is further divided by `doubleBufferSafetyFactor` to cover a
  worker's previous chunk not necessarily being garbage-collected before its
  next chunk is decoded. Skipping either margin let a generous reading, taken
  on an already-loaded machine, size a decode large enough to push the whole
  system into memory pressure.
  The resulting aggregate budget is divided across up to `cpuCount` chunks
  *before* `TiffChunkPlan.forBudget` sizes them, rather than handed to
  `forBudget` whole — otherwise, on a budget too small to fit more than one
  full tile/strip-aligned chunk at a time (a wide whole-slide-image page
  easily), `recommendedWorkerCount` always came back 1 regardless of how
  many cores were free, since chunk size (not worker count) was what used
  up the budget. Dividing first only shrinks chunks below the native
  tile/strip height (trading some redundant redecoding of the same
  tile/strip for spreading that work across otherwise-idle cores
  concurrently, rather than paying for it serially on one core) when the
  budget genuinely can't fit `cpuCount` full-sized chunks; it has no effect
  once it can, since `forBudget` already caps chunk height at the native
  tile/strip height on its own.

## 0.2.0

- `TiffChunkPlan.forBudget` computes how to decode a page in horizontal
  chunks that are both bounded by a caller-supplied byte budget and aligned
  to a whole number of tile/strip rows — decoding one row at a time (the
  natural choice for a tight memory budget) means `TiffImage.decodeRegionRgba8`
  redecodes the same underlying tile/strip once per row that overlaps it
  (500x-plus for a real whole-slide-image file's 512px tiles), since it has
  no cross-call cache; `forBudget` avoids that by only shrinking the chunk
  below one tile/strip if the budget truly forces it.
  `TiffChunkPlan.recommendedWorkerCount` derives how many such chunks can
  run concurrently within an aggregate memory budget and a CPU-count cap.
  Both are pure — no I/O, no process/OS memory reading — the budget itself
  is always an explicit parameter the caller computes however it likes.
- `TiffParallelDecoder.decodeBanded` (`package:tiff/tiff_io.dart`) decodes a
  page in horizontal bands across a pool of isolates, using `TiffChunkPlan`
  internally — each worker opens its own file handle (a decoded page can't
  cross an isolate boundary) and delivers bands back to the caller's own
  isolate as they finish, so the caller can write them out, feed a pyramid
  builder, or anything else per band without that work needing to be
  isolate-safe itself. Worker count, per-chunk budget, and band height are
  all caller-supplied.
- `TiffInitialView.forViewport` computes a centered region and display zoom
  sized for a viewer's viewport and a per-device decode budget, so a
  viewer's first frame decodes a screen-sized crop instead of the whole
  page.
- `TiffDisplayOptimizer.optimize` rewrites a page as tiled (and optionally
  pyramided) RGB, as a deliberate one-off "prepare this file" step run
  before a viewer opens it — not during interactive display — so a source
  TIFF that's strip-organized, single-resolution, or both no longer forces
  a viewer to decode more than it needs to just to pan or zoom out. Its
  `onProgress` callback reports a `TiffOptimizeProgress` (concrete
  `completedSteps`/`totalSteps` counts, plus the same as a `fraction`) once
  per pyramid rung and a final time after encoding, so a caller can show
  real "step 2 of 5" progress instead of an indefinite spinner for a large
  page.
  `ImageResampler.downsampleRgba8` (box filtering) is the pyramid-level
  resampler behind it, and is usable standalone too.
- Fixed: JPEG-in-TIFF (Compression 6/7) decoding now handles a page whose
  JPEG scan is split across strip/tile boundaries instead of each
  strip/tile being a self-contained JPEG the way TIFF Technical Note 2
  describes and this package otherwise assumes — some encoders write pages
  this way, and even the *first* chunk (SOF and all) is just as much a
  fragment as the others, since its own entropy data has nowhere near an
  EOI. Previously this surfaced as `package:image`'s
  `ImageException: Only single frame JPEGs supported` when decoding the
  second and later chunks. Each chunk is now checked upfront for its own
  SOF *and* trailing EOI — a chunk missing either is treated as part of one
  continuous scan and the whole page's chunks are reassembled into a single
  JPEG stream and decoded together instead; a chunk that has both but still
  fails to decode (corrupt data, a dimension mismatch, ...) surfaces that
  error directly rather than being incorrectly merged with unrelated,
  perfectly valid chunks (which used to be possible before this check was
  added, and would surface as a confusing
  `ImageException: Duplicate JPG frame data found.` on a page where every
  chunk actually is independently self-contained, e.g. a real whole-slide-
  image scanner file).
- Fixed: a strip/tile with a byte count of 0 (a "sparse" chunk — some
  whole-slide-image scanners never store background tiles at all, and rely
  on the reader leaving that area at its default fill value) is now skipped
  outright instead of being treated as a JPEG chunk that failed the
  self-contained check above. Previously a single sparse chunk anywhere in
  a JPEG-compressed page made *every* chunk get funneled into the
  whole-page stitched-JPEG fallback — including chunks that were perfectly
  valid, independent JPEGs on their own — which then failed with
  `ImageException: Duplicate JPG frame data found.` once more than one real
  frame ended up concatenated together. This is the shape a real
  Philips/Aperio-style whole-slide-image TIFF commonly takes.

## 0.1.0

Initial release.

- Read and write Classic TIFF (32-bit offsets) and BigTIFF (64-bit offsets),
  with automatic promotion to BigTIFF when a written image's pixel data
  would exceed the 4 GiB Classic offset limit.
- Full IFD/tag parsing, covering every baseline TIFF 6.0 tag type plus
  BigTIFF's LONG8/SLONG8/IFD8.
- Strip- and tile-organized pixel data, both reading and writing (edge tiles
  are cropped on read and zero-padded on write automatically).
- Compression: None, PackBits, LZW, and Deflate/ZIP, read and write; CCITT
  Group 3/4 fax and JPEG, read only (see the README for details on both).
  LZW decoding also transparently handles "old-style" (pre-TIFF6, LSB-first)
  data from legacy encoders, auto-detected the same way libtiff does.
  JPEG-in-TIFF decoding correctly treats the JPEG codec's own YCbCr->RGB
  conversion as final, rather than re-applying the PhotometricInterpretation
  tag's YCbCr transform on top of already-RGB samples. CCITT Group 4/2D
  decoding correctly preserves zero-length runs (some encoders pair a
  zero-length white run with a zero-length black run), which previously
  desynced the reference-line tracking used by later rows.
- Horizontal differencing predictor, read and write.
- RGBA8 color conversion covering WhiteIsZero/BlackIsZero, RGB(+alpha),
  Palette/ColorMap, CMYK, and non-subsampled YCbCr.
- Brightness/contrast/gamma adjustment for decoded RGBA8 pixel data
  (`ImageAdjustments`).
- File-backed decoding (`package:tiff/tiff_io.dart`) that streams
  strips/tiles from disk instead of loading a whole file into memory, plus
  region-of-interest decoding (`decodeRegion`/`decodeRegionRgba8`) that skips
  chunks outside a requested crop — the way to preview or tile through a
  multi-gigabyte page without materializing the whole image in memory.
- Multi-page reading and writing via IFD chains.
- GeoTIFF, EXIF, and GPS metadata parsing.
- Optional `package:image` bridge (`package:tiff/tiff_image_adapter.dart`)
  for converting to/from `image.Image` and for decoding JPEG-compressed
  pages.
