import 'dart:typed_data';

import '../core/byte_reader.dart';
import '../core/tag_value.dart';
import '../layout/chunk_decoder.dart';
import '../layout/strip_layout.dart';
import '../layout/tile_layout.dart';
import '../raster/color/color_transform.dart';
import '../raster/raster_buffer.dart';
import '../region/tiff_region.dart';
import '../tiff_exception.dart';
import 'image_metadata.dart';
import 'photometric.dart';

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

  /// Tile ([tileX], [tileY]) of a tiled, new-style JPEG (Compression 7),
  /// chunky page as one standalone JPEG stream — shared JPEGTables merged
  /// in, and for `PhotometricInterpretation=RGB` an Adobe APP14 marker
  /// declaring the samples untransformed — or null for a sparse tile (byte
  /// count 0).
  ///
  /// Nothing is decoded: this is for handing tiles to a platform JPEG codec
  /// (e.g. `dart:ui`'s, which can also decode at 1/2, 1/4 or 1/8 scale far
  /// faster than a full decode). Throws a [TiffException] if the page isn't
  /// JPEG-tiled or the tile isn't a self-contained JPEG stream.
  Uint8List? readTileJpeg(int tileX, int tileY) {
    final offsets = metadata.tileOffsets;
    final byteCounts = metadata.tileByteCounts;
    if (offsets == null || byteCounts == null || metadata.compression != 7) {
      throw const TiffException(
        'readTileJpeg needs a tiled page with new-style JPEG compression (7)',
      );
    }
    final tileWidth = metadata.tileWidth!;
    final tileLength = metadata.tileLength!;
    final tilesAcross = (metadata.width + tileWidth - 1) ~/ tileWidth;
    final tilesDown = (metadata.height + tileLength - 1) ~/ tileLength;
    RangeError.checkValueInInterval(tileX, 0, tilesAcross - 1, 'tileX');
    RangeError.checkValueInInterval(tileY, 0, tilesDown - 1, 'tileY');
    final index = tileY * tilesAcross + tileX;
    if (byteCounts[index] == 0) return null;
    final chunk = _reader.readBytes(offsets[index], byteCounts[index]);
    if (!ChunkDecoder.isSelfContainedJpeg(chunk)) {
      throw TiffException(
        'Tile ($tileX, $tileY) is not a self-contained JPEG stream',
      );
    }
    final jpeg = ChunkDecoder.standaloneJpeg(chunk, metadata.jpegTables);
    return metadata.photometric == TiffPhotometric.rgb
        ? _withAdobeRgbMarker(jpeg)
        : jpeg;
  }

  /// Most JPEG decoders assume a 3-component frame is YCbCr unless told
  /// otherwise; Adobe's APP14 marker with transform 0 is the one signal they
  /// all honor for literal RGB samples.
  static Uint8List _withAdobeRgbMarker(Uint8List jpeg) {
    const adobe = [
      0xFF, 0xEE, 0x00, 0x0E, // APP14, length 14
      0x41, 0x64, 0x6F, 0x62, 0x65, // "Adobe"
      0x00, 0x64, 0x00, 0x00, 0x00, 0x00, // version, flags0, flags1
      0x00, // transform: none
    ];
    final out = Uint8List(jpeg.length + adobe.length);
    out.setRange(0, 2, jpeg);
    out.setRange(2, 2 + adobe.length, adobe);
    out.setRange(2 + adobe.length, out.length, jpeg, 2);
    return out;
  }
}
