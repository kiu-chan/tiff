# tiff

Dart library for reading and writing TIFF and BigTIFF image files — tags, IFDs, strips/tiles, and common compression schemes.

## Status

Phase 1 + 2 implemented: reading Classic TIFF and BigTIFF, strip and tile
data, common compression schemes, and RGBA color conversion.

## Features

- [x] Classic TIFF (32-bit offsets)
- [x] BigTIFF (64-bit offsets)
- [x] IFD / tag parsing (all baseline tag types, incl. BigTIFF LONG8/SLONG8/IFD8)
- [x] Strip decoding
- [x] Tile decoding (incl. cropped edge tiles)
- [x] Compression: None, PackBits, LZW, Deflate/ZIP
- [x] Horizontal differencing predictor
- [x] RGBA8 color conversion: WhiteIsZero/BlackIsZero, RGB(+alpha), Palette,
      CMYK, non-subsampled YCbCr
- [x] File-backed decoding without loading the whole file into memory
      (`package:tiff/tiff_io.dart`)
- [x] Region-of-interest decoding (skip strips/tiles outside a requested crop)
- [ ] JPEG-in-TIFF, CCITT Group 3/4 compression
- [ ] Encoding (write TIFF/BigTIFF)
- [ ] GeoTIFF / EXIF metadata

## Getting started

```yaml
dependencies:
  tiff: ^0.1.0
```

## Usage

```dart
import 'dart:io';
import 'package:tiff/tiff.dart';

void main() {
  final bytes = File('image.tif').readAsBytesSync();
  final document = TiffDecoder.decode(bytes);

  for (final page in document.images) {
    print('${page.metadata.width}x${page.metadata.height}, '
        '${page.metadata.samplesPerPixel} samples/pixel');
    final raster = page.decode(); // raw samples, no color interpretation
    print(raster.sampleAt(0, 0, 0));
    final rgba = page.decodeRgba8(); // interleaved 8-bit RGBA
  }
}
```

For large (BigTIFF) files, decode directly from disk instead of loading the
whole file into memory, and optionally decode just a crop:

```dart
import 'dart:io';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_io.dart'; // dart:io-backed, not available on web

void main() {
  final document = decodeTiffFile(File('huge.tif'));
  try {
    final page = document.images.first;
    final crop = page.decodeRegion(TiffRegion(x: 0, y: 0, width: 512, height: 512));
    print(crop.sampleAt(0, 0, 0));
  } finally {
    document.close(); // releases the file handle
  }
}
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
