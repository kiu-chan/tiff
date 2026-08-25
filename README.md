# tiff

Dart library for reading and writing TIFF and BigTIFF image files — tags, IFDs, strips/tiles, and common compression schemes.

## Status

Phase 1 implemented: reading Classic TIFF and BigTIFF, uncompressed strip data.

## Features

- [x] Classic TIFF (32-bit offsets)
- [x] BigTIFF (64-bit offsets)
- [x] IFD / tag parsing (all baseline tag types, incl. BigTIFF LONG8/SLONG8/IFD8)
- [x] Strip decoding (uncompressed)
- [ ] Tile decoding
- [ ] Compression schemes (LZW, PackBits, Deflate)
- [ ] Streaming/lazy decode for large (multi-GB) BigTIFF files
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
    final raster = page.decode(); // uncompressed strips only, for now
    print(raster.sampleAt(0, 0, 0));
  }
}
```

## License

Apache License 2.0. See [LICENSE](LICENSE).
