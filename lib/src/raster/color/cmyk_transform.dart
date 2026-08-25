import 'dart:typed_data';

import '../../tiff_exception.dart';
import '../raster_buffer.dart';

/// CMYK -> RGBA8 using the standard subtractive-color formula
/// `R = 255 * (1-C) * (1-K)` (and similarly for G/B).
class CmykTransform {
  const CmykTransform._();

  static Uint8List toRgba8(TiffRasterBuffer raster) {
    if (raster.samplesPerPixel < 4) {
      throw TiffException('CMYK photometric requires 4 samples per pixel, got ${raster.samplesPerPixel}');
    }
    final maxValue = (1 << raster.bitsPerSample) - 1;
    final pixelCount = raster.width * raster.height;
    final out = Uint8List(pixelCount * 4);

    for (var p = 0; p < pixelCount; p++) {
      final base = p * raster.samplesPerPixel;
      final c = raster.samples[base] / maxValue;
      final m = raster.samples[base + 1] / maxValue;
      final y = raster.samples[base + 2] / maxValue;
      final k = raster.samples[base + 3] / maxValue;
      final o = p * 4;
      out[o] = (255 * (1 - c) * (1 - k)).round().clamp(0, 255);
      out[o + 1] = (255 * (1 - m) * (1 - k)).round().clamp(0, 255);
      out[o + 2] = (255 * (1 - y) * (1 - k)).round().clamp(0, 255);
      out[o + 3] = 255;
    }
    return out;
  }
}
