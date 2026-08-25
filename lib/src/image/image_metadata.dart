import '../core/tag_value.dart';
import '../tags/tag_id.dart';
import '../tiff_exception.dart';
import 'photometric.dart';
import 'planar_configuration.dart';

/// Decoded baseline metadata for a single TIFF page (one IFD), independent
/// of how the pixel data is laid out (strip vs tile) or compressed.
class TiffImageMetadata {
  final int width;
  final int height;
  final List<int> bitsPerSample;
  final int samplesPerPixel;
  final int compression;
  final TiffPhotometric? photometric;
  final TiffPlanarConfiguration planarConfiguration;
  final int rowsPerStrip;
  final List<int> stripOffsets;
  final List<int> stripByteCounts;
  final List<int>? colorMap;

  /// Every tag found in this page's IFD, resolved but unfiltered — use this
  /// for tags not modeled above (ImageDescription, GeoTIFF keys, EXIF, ...).
  final Map<int, TiffTagValue> rawTags;

  const TiffImageMetadata({
    required this.width,
    required this.height,
    required this.bitsPerSample,
    required this.samplesPerPixel,
    required this.compression,
    required this.photometric,
    required this.planarConfiguration,
    required this.rowsPerStrip,
    required this.stripOffsets,
    required this.stripByteCounts,
    required this.colorMap,
    required this.rawTags,
  });

  factory TiffImageMetadata.fromTags(Map<int, TiffTagValue> tags) {
    int requireInt(int tagId, String name) {
      final value = tags[tagId];
      if (value == null) throw TiffException('Missing required tag $name ($tagId)');
      return value.asInt();
    }

    final width = requireInt(TiffTagId.imageWidth, 'ImageWidth');
    final height = requireInt(TiffTagId.imageLength, 'ImageLength');
    final samplesPerPixel = tags[TiffTagId.samplesPerPixel]?.asInt() ?? 1;
    final bitsPerSample = tags[TiffTagId.bitsPerSample]?.asIntList() ?? List.filled(samplesPerPixel, 1);
    final compression = tags[TiffTagId.compression]?.asInt() ?? 1;

    final photometricCode = tags[TiffTagId.photometricInterpretation]?.asInt();
    final photometric = photometricCode == null ? null : TiffPhotometric.fromCode(photometricCode);

    final planarConfiguration =
        TiffPlanarConfiguration.fromCode(tags[TiffTagId.planarConfiguration]?.asInt() ?? 1);
    final rowsPerStrip = tags[TiffTagId.rowsPerStrip]?.asInt() ?? height;

    final stripOffsetsTag = tags[TiffTagId.stripOffsets];
    final stripByteCountsTag = tags[TiffTagId.stripByteCounts];
    if (stripOffsetsTag == null || stripByteCountsTag == null) {
      if (tags.containsKey(TiffTagId.tileOffsets)) {
        throw const TiffException(
            'Tile-based images are not supported yet (Phase 1 supports strip-based images only)');
      }
      throw const TiffException('Missing StripOffsets/StripByteCounts tags');
    }

    return TiffImageMetadata(
      width: width,
      height: height,
      bitsPerSample: bitsPerSample,
      samplesPerPixel: samplesPerPixel,
      compression: compression,
      photometric: photometric,
      planarConfiguration: planarConfiguration,
      rowsPerStrip: rowsPerStrip,
      stripOffsets: stripOffsetsTag.asIntList(),
      stripByteCounts: stripByteCountsTag.asIntList(),
      colorMap: tags[TiffTagId.colorMap]?.asIntList(),
      rawTags: tags,
    );
  }
}
