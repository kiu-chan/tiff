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
    final samples = raster.samples;
    final spp = raster.samplesPerPixel;

    // 8-bit is the by far most common depth, where _scale's job is exactly
    // the identity (maxValue == 255) — skip its float divide-and-round
    // entirely rather than compute a no-op per channel per pixel.
    if (maxValue == 255) {
      for (var p = 0; p < pixelCount; p++) {
        final base = p * spp;
        final o = p * 4;
        out[o] = samples[base];
        out[o + 1] = samples[base + 1];
        out[o + 2] = samples[base + 2];
        out[o + 3] = hasAlpha ? samples[base + 3] : 255;
      }
      return out;
    }

    for (var p = 0; p < pixelCount; p++) {
      final base = p * spp;
      final o = p * 4;
      out[o] = _scale(samples[base], maxValue);
      out[o + 1] = _scale(samples[base + 1], maxValue);
      out[o + 2] = _scale(samples[base + 2], maxValue);
      out[o + 3] = hasAlpha ? _scale(samples[base + 3], maxValue) : 255;
    }
    return out;
  }

  static int _scale(int value, int maxValue) =>
      maxValue == 0 ? 0 : ((value * 255) / maxValue).round().clamp(0, 255);
}
