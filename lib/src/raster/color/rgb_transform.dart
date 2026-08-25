import 'dart:typed_data';

import '../../tiff_exception.dart';
import '../raster_buffer.dart';

/// RGB (optionally RGBA, if ExtraSamples indicates a 4th alpha channel) ->
/// RGBA8.
class RgbTransform {
  const RgbTransform._();

  static Uint8List toRgba8(TiffRasterBuffer raster) {
    if (raster.samplesPerPixel < 3) {
      throw TiffException(
        'RGB photometric requires at least 3 samples per pixel, got ${raster.samplesPerPixel}',
      );
    }
    final maxValue = (1 << raster.bitsPerSample) - 1;
    final hasAlpha = raster.samplesPerPixel >= 4;
    final pixelCount = raster.width * raster.height;
    final out = Uint8List(pixelCount * 4);

    for (var p = 0; p < pixelCount; p++) {
      final base = p * raster.samplesPerPixel;
      final o = p * 4;
      out[o] = _scale(raster.samples[base], maxValue);
      out[o + 1] = _scale(raster.samples[base + 1], maxValue);
      out[o + 2] = _scale(raster.samples[base + 2], maxValue);
      out[o + 3] = hasAlpha ? _scale(raster.samples[base + 3], maxValue) : 255;
    }
    return out;
  }

  static int _scale(int value, int maxValue) =>
      maxValue == 0 ? 0 : ((value * 255) / maxValue).round().clamp(0, 255);
}
