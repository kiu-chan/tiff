## 0.2.0

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
