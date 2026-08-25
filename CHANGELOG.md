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
- Horizontal differencing predictor, read and write.
- RGBA8 color conversion covering WhiteIsZero/BlackIsZero, RGB(+alpha),
  Palette/ColorMap, CMYK, and non-subsampled YCbCr.
- File-backed decoding (`package:tiff/tiff_io.dart`) that streams
  strips/tiles from disk instead of loading a whole file into memory, plus
  region-of-interest decoding that skips chunks outside a requested crop.
- Multi-page reading and writing via IFD chains.
- GeoTIFF, EXIF, and GPS metadata parsing.
- Optional `package:image` bridge (`package:tiff/tiff_image_adapter.dart`)
  for converting to/from `image.Image` and for decoding JPEG-compressed
  pages.
