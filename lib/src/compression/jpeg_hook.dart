import 'dart:typed_data';

/// Decodes one already-assembled JPEG stream (SOI...EOI) into interleaved,
/// 8-bit-per-channel samples, row-major, length
/// `columns * rows * samplesPerPixel`.
typedef JpegDecodeFn =
    Uint8List Function(
      Uint8List jpegBytes, {
      required int columns,
      required int rows,
      required int samplesPerPixel,
    });

/// TIFF's baseline spec has no bundled JPEG codec, and this package doesn't
/// depend on one — decoding Compression 6 ("old-style" JPEG) or 7 ("new-style"
/// JPEG) strips/tiles needs a decoder plugged in here.
/// `package:tiff/tiff_image_adapter.dart` provides one backed by
/// `package:image`; call its `TiffImageAdapter.enableJpegSupport()` once
/// before decoding a JPEG-compressed TIFF.
class JpegCodecHook {
  const JpegCodecHook._();

  static JpegDecodeFn? decoder;
}
