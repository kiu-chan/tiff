import 'dart:typed_data';

import '../raster_buffer.dart';

/// WhiteIsZero / BlackIsZero -> RGBA8 (each sample becomes an equal R=G=B).
class GrayscaleTransform {
  const GrayscaleTransform._();

  static Uint8List toRgba8(TiffRasterBuffer raster, {required bool invert}) {
    final maxValue = (1 << raster.bitsPerSample) - 1;
    final pixelCount = raster.width * raster.height;
    final out = Uint8List(pixelCount * 4);
    final samples = raster.samples;
    final spp = raster.samplesPerPixel;
    for (var p = 0; p < pixelCount; p++) {
      final raw = samples[p * spp];
      // 8-bit is the common case, where scaling to 0..255 is the identity —
      // skip the float divide-and-round for it.
      var v8 = maxValue == 255
          ? raw
          : maxValue == 0
          ? 0
          : ((raw * 255) / maxValue).round().clamp(0, 255);
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
