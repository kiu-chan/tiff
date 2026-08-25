import 'dart:typed_data';

import '../../image/image_metadata.dart';
import '../../tiff_exception.dart';
import '../raster_buffer.dart';

/// Palette (indexed color) -> RGBA8, using the page's ColorMap tag.
///
/// ColorMap stores three lookup tables back to back (R, then G, then B),
/// each with `2^BitsPerSample` 16-bit entries; a sample value is a palette
/// index, not a color component.
class PaletteTransform {
  const PaletteTransform._();

  static Uint8List toRgba8(
    TiffRasterBuffer raster,
    TiffImageMetadata metadata,
  ) {
    final colorMap = metadata.colorMap;
    if (colorMap == null) {
      throw const TiffException('Palette photometric requires a ColorMap tag');
    }
    final entries = 1 << raster.bitsPerSample;
    if (colorMap.length < entries * 3) {
      throw TiffException(
        'ColorMap has ${colorMap.length} entries, expected at least ${entries * 3}',
      );
    }

    final pixelCount = raster.width * raster.height;
    final out = Uint8List(pixelCount * 4);
    for (var p = 0; p < pixelCount; p++) {
      final index = raster.samples[p * raster.samplesPerPixel];
      final o = p * 4;
      out[o] = colorMap[index] >> 8;
      out[o + 1] = colorMap[entries + index] >> 8;
      out[o + 2] = colorMap[entries * 2 + index] >> 8;
      out[o + 3] = 255;
    }
    return out;
  }
}
