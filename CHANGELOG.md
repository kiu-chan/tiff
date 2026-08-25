## 0.1.0

- Initial scaffold.
- Phase 1: read Classic TIFF and BigTIFF headers, IFD chains (multi-page),
  all baseline tag types, and decode uncompressed strip-organized pixel
  data (1/2/4/8/16/32-bit samples, any PlanarConfiguration=chunky layout).
- Phase 2: compression codecs (PackBits, LZW, Deflate/ZIP) and the
  horizontal differencing predictor; tile-organized pixel data (with edge
  tile cropping); color transforms to interleaved RGBA8
  (WhiteIsZero/BlackIsZero, RGB(+alpha), Palette/ColorMap, CMYK,
  non-subsampled YCbCr) via `TiffImage.decodeRgba8()`.
- Phase 3: pluggable byte sources (`TiffByteSource`) so decoding no longer
  requires the whole file in memory; `package:tiff/tiff_io.dart` adds a
  `dart:io`-backed `FileByteSource`/`decodeTiffFile` that reads a file
  on demand through a buffered sliding window. `TiffImage.decodeRegion()`
  decodes only the strips/tiles overlapping a requested rectangle,
  skipping the read entirely for the rest — the way to look at a crop of
  a multi-gigabyte BigTIFF page without decoding the whole thing.
- Phase 4: `TiffEncoder.encode()` writes Classic TIFF or BigTIFF from one
  or more `TiffImageSpec` pages — strip or tile layout, PackBits/LZW/Deflate
  compression, the horizontal differencing predictor, and Palette/ColorMap
  images. BigTIFF is auto-selected once the encoded pixel data approaches
  the 4 GiB Classic offset limit (or force it explicitly either way).
