# tiff

Dart library for reading and writing TIFF and BigTIFF image files — tags, IFDs, strips/tiles, and common compression schemes.

## Status

Phases 1-4 implemented: reading and writing Classic TIFF and BigTIFF, strip
and tile data, common compression schemes, and RGBA color conversion.

## Features

- [x] Classic TIFF (32-bit offsets)
- [x] BigTIFF (64-bit offsets), incl. auto-promotion from Classic on write
- [x] IFD / tag parsing (all baseline tag types, incl. BigTIFF LONG8/SLONG8/IFD8)
- [x] Strip decoding and encoding
- [x] Tile decoding and encoding (incl. cropped/padded edge tiles)
- [x] Compression: None, PackBits, LZW, Deflate/ZIP (read and write)
- [x] Horizontal differencing predictor (read and write)
- [x] RGBA8 color conversion: WhiteIsZero/BlackIsZero, RGB(+alpha), Palette,
      CMYK, non-subsampled YCbCr
- [x] File-backed decoding without loading the whole file into memory
      (`package:tiff/tiff_io.dart`)
- [x] Region-of-interest decoding (skip strips/tiles outside a requested crop)
- [x] Multi-page writing
- [ ] JPEG-in-TIFF, CCITT Group 3/4 compression
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

Writing a TIFF:

```dart
import 'dart:io';
import 'package:tiff/tiff.dart';

void main() {
  final spec = TiffImageSpec(
    width: 256,
    height: 256,
    samplesPerPixel: 3,
    bitsPerSample: 8,
    photometric: TiffPhotometric.rgb,
    samples: myRgbSamples, // length == width * height * samplesPerPixel
    compression: 5, // LZW; see TiffTagId-style compression codes in the docs
    predictor: 2, // horizontal differencing (pairs well with LZW/Deflate)
  );

  final bytes = TiffEncoder.encode([spec]); // pass multiple specs for a multi-page file
  File('output.tif').writeAsBytesSync(bytes);
}
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
