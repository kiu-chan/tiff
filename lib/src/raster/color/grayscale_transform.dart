import 'dart:typed_data';

import '../raster_buffer.dart';

/// WhiteIsZero / BlackIsZero -> RGBA8 (each sample becomes an equal R=G=B).
class GrayscaleTransform {
  const GrayscaleTransform._();

  static Uint8List toRgba8(TiffRasterBuffer raster, {required bool invert}) {
    final maxValue = (1 << raster.bitsPerSample) - 1;
    final pixelCount = raster.width * raster.height;
    final out = Uint8List(pixelCount * 4);
    for (var p = 0; p < pixelCount; p++) {
      final raw = raster.samples[p * raster.samplesPerPixel];
      var v8 = maxValue == 0 ? 0 : ((raw * 255) / maxValue).round().clamp(0, 255);
      if (invert) v8 = 255 - v8;
      final o = p * 4;
      out[o] = v8;
      out[o + 1] = v8;
      out[o + 2] = v8;
      out[o + 3] = 255;
    }
    return out;
  }
}
