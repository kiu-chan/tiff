## 0.2.0

- `TiffInitialView.forViewport` computes a centered region and display zoom
  sized for a viewer's viewport and a per-device decode budget, so a
  viewer's first frame decodes a screen-sized crop instead of the whole
  page.
- `TiffDisplayOptimizer.optimize` rewrites a page as tiled (and optionally
  pyramided) RGB, as a deliberate one-off "prepare this file" step run
  before a viewer opens it — not during interactive display — so a source
  TIFF that's strip-organized, single-resolution, or both no longer forces
  a viewer to decode more than it needs to just to pan or zoom out.
  `ImageResampler.downsampleRgba8` (box filtering) is the pyramid-level
  resampler behind it, and is usable standalone too.

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
