import 'dart:typed_data';

import '../core/byte_reader.dart';
import '../core/tag_value.dart';
import '../layout/strip_layout.dart';
import '../layout/tile_layout.dart';
import '../raster/color/color_transform.dart';
import '../raster/raster_buffer.dart';
import '../region/tiff_region.dart';
import 'image_metadata.dart';

/// One page (IFD) of a TIFF/BigTIFF file: its metadata, plus the ability to
/// decode its pixel data on demand.
class TiffImage {
  final TiffImageMetadata metadata;
  final TiffByteReader _reader;

  const TiffImage._(this.metadata, this._reader);

  factory TiffImage.fromTags(
    Map<int, TiffTagValue> tags,
    TiffByteReader reader, {
    required bool isBigTiff,
  }) => TiffImage._(
    TiffImageMetadata.fromTags(tags, reader: reader, isBigTiff: isBigTiff),
    reader,
  );

  /// Decodes this page's pixel data into raw, unpacked samples (no color
  /// interpretation applied — see [decodeRgba8] for that).
  TiffRasterBuffer decode() {
    if (metadata.isTiled) {
      return TileLayout.decode(reader: _reader, metadata: metadata);
    }
    return StripLayout.decode(reader: _reader, metadata: metadata);
  }

  /// Decodes only [region] of this page's pixel data.
  ///
  /// Strips/tiles entirely outside [region] are never read or decoded —
  /// for a file-backed source (see `package:tiff/tiff_io.dart`), that
  /// means they're never even read from disk. This is the way to look at
  /// a small crop of a multi-gigabyte BigTIFF page without materializing
  /// the whole thing.
  TiffRasterBuffer decodeRegion(TiffRegion region) {
    if (metadata.isTiled) {
      return TileLayout.decodeRegion(
        reader: _reader,
        metadata: metadata,
        region: region,
      );
    }
    return StripLayout.decodeRegion(
      reader: _reader,
      metadata: metadata,
      region: region,
    );
  }

  /// Decodes and converts to interleaved 8-bit RGBA, applying the page's
  /// PhotometricInterpretation (grayscale, RGB, palette, CMYK, or
  /// non-subsampled YCbCr).
  Uint8List decodeRgba8() => ColorTransform.toRgba8(metadata, decode());

  /// [decodeRegion] followed by the same RGBA8 conversion [decodeRgba8]
  /// applies — the way to get a low-memory RGBA preview of a crop from a
  /// multi-gigabyte page without ever materializing the whole image.
  Uint8List decodeRegionRgba8(TiffRegion region) =>
      ColorTransform.toRgba8(metadata, decodeRegion(region));
}
