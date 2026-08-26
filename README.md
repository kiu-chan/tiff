# tiff

A Dart library for reading and writing TIFF and BigTIFF image files: tags
and IFDs, strip/tile pixel data, common compression schemes, color
conversion, and GeoTIFF/EXIF metadata — for files ranging from a few
kilobytes to multi-gigabyte BigTIFF rasters.

## Features

- Classic TIFF (32-bit offsets) and BigTIFF (64-bit offsets), with automatic
  promotion to BigTIFF on write when the pixel data would exceed Classic's
  4 GiB offset limit
- Full IFD/tag parsing, including every baseline TIFF 6.0 tag type plus
  BigTIFF's LONG8/SLONG8/IFD8
- Strip and tile pixel data, reading and writing (edge tiles are cropped on
  read and zero-padded on write automatically)
- Compression: None, PackBits, LZW, and Deflate/ZIP, read and write; CCITT
  Group 3/4 fax and JPEG, read only (see [Limitations](#limitations))
- Horizontal differencing predictor, read and write
- RGBA8 color conversion: WhiteIsZero/BlackIsZero, RGB(+alpha),
  Palette/ColorMap, CMYK, and non-subsampled YCbCr
- Brightness/contrast/gamma adjustment on decoded RGBA8 pixel data
  (`ImageAdjustments`)
- File-backed decoding that streams strips/tiles from disk instead of
  loading a whole file into memory (`package:tiff/tiff_io.dart`), plus
  region-of-interest decoding that skips chunks outside a requested crop
- `TiffInitialView.forViewport` picks a centered region and zoom level sized
  for a viewer's screen and decode budget, so a first frame never requires
  decoding a whole multi-gigapixel page
- `TiffDisplayOptimizer.optimize` rewrites a page as tiled (and optionally
  pyramided) RGB ahead of time, so a strip-organized and/or
  single-resolution source no longer forces a viewer to decode more than it
  needs to
- Multi-page reading and writing via IFD chains
- GeoTIFF, EXIF, and GPS metadata parsing
- An optional `package:image` bridge (`package:tiff/tiff_image_adapter.dart`)
  for converting to/from `image.Image` and for decoding JPEG-compressed pages

## Limitations

- **CCITT Group 3/4 fax (Compression 2/3/4) is decode-only.** Virtually no
  modern software writes new Group 3/4 data, so encoding it isn't
  implemented.
- **JPEG-in-TIFF (Compression 6/7) decoding requires the optional adapter**
  (`package:tiff/tiff_image_adapter.dart`) — TIFF's baseline spec has no
  bundled JPEG codec, so this package borrows `package:image`'s. Writing
  JPEG-compressed TIFF is not supported. Normally each strip/tile is its own
  self-contained JPEG (TIFF Technical Note 2) and only the strips/tiles a
  region actually touches get decoded; a page whose encoder instead split
  one continuous JPEG scan across chunk boundaries still decodes correctly,
  but any `decodeRegion` call against it costs as much as decoding the
  whole page — there's no way to decode part of one continuous scan.
- Only chunky (interleaved) `PlanarConfiguration`, and a single
  `BitsPerSample` value uniform across channels, are supported.

## Getting started

```yaml
dependencies:
  tiff: ^0.2.0
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

For a viewer's first frame, decode a region sized for the screen instead of
the whole page — `TiffInitialView.forViewport` picks a region centered on
the page plus the zoom to display it at, capped by a decode budget you tune
per device:

```dart
final page = document.images.first;
final initialView = TiffInitialView.forViewport(
  page.metadata,
  viewportWidth: 1080,
  viewportHeight: 2280,
  devicePixelRatio: 3.0, // from the platform, e.g. MediaQuery in Flutter
  maxDecodedPixels: 4000000, // lower this on memory-constrained devices
);
final preview = page.decodeRegionRgba8(initialView.region);
// Display `preview` scaled by initialView.zoom, then let the user pan/zoom
// further, decoding new regions on demand.
```

Preparing a file *ahead of time* so a later viewer never has to decode more
than it needs to — this is a deliberate one-off rewrite, not something to
run during interactive display, and it decodes the whole page into memory
to do it (see the `TiffDisplayOptimizer` dartdoc for the memory caveat on a
very large page):

```dart
final page = document.images.first;
final optimized = TiffDisplayOptimizer.optimize(
  page,
  mode: TiffOptimizationMode.tiledPyramid, // or .tiledOnly for just re-tiling
  tileSize: 512,
  minPyramidDimension: 512,
);
File('optimized.tif').writeAsBytesSync(optimized);
// optimized.tif is tiled RGB with progressively halved rungs appended as
// extra pages — open it the normal way and a viewer can decode by tile at
// whichever rung matches the current zoom, instead of the whole page.
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

Reading GeoTIFF/EXIF metadata (present on the decoded page's `metadata`, no
extra setup needed):

```dart
final metadata = page.metadata;
final geo = metadata.geoTiff; // null if the file has no GeoTIFF tags
if (geo != null) {
  print(geo.modelPixelScale); // [scaleX, scaleY, scaleZ]
  print(geo.geoKeys[GeoTiffKeyId.gtModelType]);
}
print(metadata.exifTags?[ExifTagId.dateTimeOriginal]?.asString());
```

Adjusting brightness/contrast/gamma on decoded pixels:

```dart
final rgba = page.decodeRgba8();
final adjusted = ImageAdjustments.apply(
  rgba,
  brightness: 15, // additive, sample units; negative darkens
  contrast: 1.2, // 1.0 = no change, around mid-gray
  gamma: 1.1, // 1.0 = no change; >1 brightens midtones
);
```

### Optional: `package:image` bridge

`package:tiff/tiff.dart` never depends on `package:image` — that stays a
lightweight import for anyone who only needs raw TIFF pixels. Import
`package:tiff/tiff_image_adapter.dart` as well to convert to/from
`image.Image`, or to decode JPEG-compressed TIFF pages (Compression 6/7),
which TIFF's baseline spec has no bundled codec for:

```dart
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_image_adapter.dart';

void main() {
  TiffImageAdapter.enableJpegSupport(); // needed once, only for Compression 6/7 pages

  final page = TiffDecoder.decode(bytes).images.first;
  final image = TiffImageAdapter.toImage(page); // an image.Image, ready for
  // cropping/resizing/PNG export/etc. via package:image

  final spec = TiffImageAdapter.toTiffImageSpec(image); // back to TIFF
  File('roundtrip.tif').writeAsBytesSync(TiffEncoder.encode([spec]));
}
```

Note: `package:image` is still a normal (if rarely large) entry in this
package's `pubspec.yaml` — Dart has no per-file-optional dependency
mechanism, so `dart pub get` fetches it for every consumer regardless of
whether `tiff_image_adapter.dart` is ever imported. "Optional" here means
your own code never has to touch `package:image`'s API (or pay for importing
it) unless you choose to.

## Example app

See [tiff_tester](https://github.com/kiu-chan/tiff_tester.git) for a full
Flutter app example built on this package.

## Support

If this package is useful to you, consider supporting its development on
Ko-fi:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/monlycute)

## License

Apache License 2.0. See [LICENSE](LICENSE).
