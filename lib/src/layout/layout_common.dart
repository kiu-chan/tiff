import '../image/image_metadata.dart';
import '../image/planar_configuration.dart';
import '../tiff_exception.dart';

/// Validation shared by [StripLayout] and [TileLayout]: chunky-only layout,
/// and a single BitsPerSample value uniform across channels.
class LayoutCommon {
  const LayoutCommon._();

  static int uniformBitsPerSample(TiffImageMetadata metadata) {
    if (metadata.planarConfiguration == TiffPlanarConfiguration.planar) {
      throw const TiffException(
        'Planar configuration is not supported yet (chunky/interleaved data only)',
      );
    }
    final bitsSet = metadata.bitsPerSample.toSet();
    if (bitsSet.length > 1) {
      throw const TiffException(
        'Differing BitsPerSample per channel is not supported yet',
      );
    }
    return metadata.bitsPerSample.isNotEmpty ? metadata.bitsPerSample.first : 1;
  }
}
