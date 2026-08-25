import 'dart:typed_data';

import '../../image/image_metadata.dart';
import '../../image/photometric.dart';
import '../../tags/tag_id.dart';
import '../../tiff_exception.dart';
import '../raster_buffer.dart';
import 'cmyk_transform.dart';
import 'grayscale_transform.dart';
import 'palette_transform.dart';
import 'rgb_transform.dart';
import 'ycbcr_transform.dart';

/// Picks and applies the color transform matching a page's
/// PhotometricInterpretation, producing interleaved 8-bit RGBA.
class ColorTransform {
  const ColorTransform._();

  static Uint8List toRgba8(
    TiffImageMetadata metadata,
    TiffRasterBuffer raster,
  ) {
    final photometric = metadata.photometric;
    if (photometric == null) {
      throw const TiffException(
        'Cannot convert to RGBA: PhotometricInterpretation tag is missing',
      );
    }

    switch (photometric) {
      case TiffPhotometric.whiteIsZero:
        return GrayscaleTransform.toRgba8(raster, invert: true);
      case TiffPhotometric.blackIsZero:
        return GrayscaleTransform.toRgba8(raster, invert: false);
      case TiffPhotometric.rgb:
        return RgbTransform.toRgba8(raster);
      case TiffPhotometric.palette:
        return PaletteTransform.toRgba8(raster, metadata);
      case TiffPhotometric.cmyk:
        return CmykTransform.toRgba8(raster);
      case TiffPhotometric.ycbcr:
        final subsampling =
            metadata.rawTags[TiffTagId.yCbCrSubSampling]?.asIntList() ?? [2, 2];
        if (subsampling[0] != 1 || subsampling[1] != 1) {
          throw TiffException(
            'Subsampled YCbCr (${subsampling[0]}x${subsampling[1]}) is not supported yet; only 1x1 (no subsampling) is supported',
          );
        }
        return YCbCrTransform.toRgba8(raster);
      case TiffPhotometric.transparencyMask:
      case TiffPhotometric.cielab:
        throw TiffException(
          'PhotometricInterpretation ${photometric.name} is not supported yet',
        );
    }
  }
}
