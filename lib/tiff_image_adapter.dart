/// Optional bridge to `package:image`.
///
/// `package:tiff` never imports `package:image` from its main entry point
/// (`package:tiff/tiff.dart`) — that stays a lightweight, `package:image`-free
/// dependency for anyone who only needs to read/write TIFF pixels directly.
/// Import *this* library instead when you want to:
///
///  - convert a decoded [TiffImage] to an `image.Image` (crop/resize/composite
///    it, save it as PNG, etc. using the wider `image` ecosystem), or
///  - build a [TiffImageSpec] from an `image.Image` to write it out as TIFF, or
///  - decode JPEG-compressed TIFF strips/tiles (Compression 6/7) — TIFF's
///    baseline spec has no bundled JPEG codec, so this is the only way to
///    read those without bringing your own decoder.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'src/compression/jpeg_hook.dart';
import 'tiff.dart';

/// Converts between [TiffImage]/[TiffImageSpec] and `package:image`'s
/// [img.Image].
class TiffImageAdapter {
  const TiffImageAdapter._();

  /// Registers `package:image`'s JPEG decoder as the codec used for
  /// Compression 6/7 (JPEG-in-TIFF) strips/tiles. Call this once before
  /// decoding a JPEG-compressed TIFF — without it, [TiffImage.decode] throws
  /// a clear error for those pages instead of silently failing.
  static void enableJpegSupport() {
    JpegCodecHook.decoder = _decodeJpegChunk;
  }

  static Uint8List _decodeJpegChunk(
    Uint8List jpegBytes, {
    required int columns,
    required int rows,
    required int samplesPerPixel,
  }) {
    final decoded = img.decodeJpg(jpegBytes);
    if (decoded == null) {
      throw const TiffException('package:image failed to decode a JPEG-compressed TIFF chunk');
    }
    if (decoded.width != columns || decoded.height != rows) {
      throw TiffException(
          'JPEG chunk decoded to ${decoded.width}x${decoded.height}, expected ${columns}x$rows');
    }
    final order = switch (samplesPerPixel) {
      1 => img.ChannelOrder.red,
      3 => img.ChannelOrder.rgb,
      4 => img.ChannelOrder.rgba,
      _ => throw TiffException('JPEG-in-TIFF with $samplesPerPixel samples/pixel is not supported'),
    };
    return decoded.getBytes(order: order);
  }

  /// Converts a decoded TIFF page to an 8-bit RGBA `image.Image`, applying
  /// its PhotometricInterpretation (same color handling as
  /// [TiffImage.decodeRgba8]).
  static img.Image toImage(TiffImage page) {
    final rgba = page.decodeRgba8();
    return img.Image.fromBytes(
      width: page.metadata.width,
      height: page.metadata.height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
  }

  /// Builds a [TiffImageSpec] for writing [image] out as an 8-bit TIFF page
  /// (RGB, or RGBA if [keepAlpha] is true and [image] has an alpha channel).
  ///
  /// [compression]/[predictor] are passed straight through to the spec —
  /// see [TiffImageSpec] for the accepted values.
  static TiffImageSpec toTiffImageSpec(
    img.Image image, {
    bool keepAlpha = false,
    int compression = 1,
    int predictor = 1,
    int? rowsPerStrip,
    int? tileWidth,
    int? tileLength,
  }) {
    final useAlpha = keepAlpha && image.hasAlpha;
    final samples = image.getBytes(order: useAlpha ? img.ChannelOrder.rgba : img.ChannelOrder.rgb);
    return TiffImageSpec(
      width: image.width,
      height: image.height,
      samplesPerPixel: useAlpha ? 4 : 3,
      bitsPerSample: 8,
      photometric: TiffPhotometric.rgb,
      samples: samples,
      compression: compression,
      predictor: predictor,
      rowsPerStrip: rowsPerStrip,
      tileWidth: tileWidth,
      tileLength: tileLength,
    );
  }
}
