import 'dart:typed_data';

import '../../tiff_exception.dart';
import '../raster_buffer.dart';

/// Non-subsampled YCbCr -> RGBA8 using the ITU-R BT.601 coefficients (the
/// same conversion baseline JPEG uses).
class YCbCrTransform {
  const YCbCrTransform._();

  static Uint8List toRgba8(TiffRasterBuffer raster) {
    if (raster.samplesPerPixel < 3) {
      throw TiffException(
        'YCbCr photometric requires 3 samples per pixel, got ${raster.samplesPerPixel}',
      );
    }
    final pixelCount = raster.width * raster.height;
    final out = Uint8List(pixelCount * 4);

    for (var p = 0; p < pixelCount; p++) {
      final base = p * raster.samplesPerPixel;
      final y = raster.samples[base].toDouble();
      final cb = raster.samples[base + 1].toDouble() - 128;
      final cr = raster.samples[base + 2].toDouble() - 128;
      final o = p * 4;
      out[o] = (y + 1.402 * cr).round().clamp(0, 255);
      out[o + 1] = (y - 0.344136 * cb - 0.714136 * cr).round().clamp(0, 255);
      out[o + 2] = (y + 1.772 * cb).round().clamp(0, 255);
      out[o + 3] = 255;
    }
    return out;
  }
}
