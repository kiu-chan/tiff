import '../core/tag_value.dart';
import '../tags/tag_id.dart';
import '../tiff_exception.dart';
import 'photometric.dart';
import 'planar_configuration.dart';

/// Decoded baseline metadata for a single TIFF page (one IFD), independent
/// of how the pixel data is compressed. Pixel data is located either via
/// strip tags or tile tags — exactly one of the two is populated, see
/// [isTiled].
class TiffImageMetadata {
  final int width;
  final int height;
  final List<int> bitsPerSample;
  final int samplesPerPixel;
  final int compression;
  final int predictor;
  final TiffPhotometric? photometric;
  final TiffPlanarConfiguration planarConfiguration;
  final int rowsPerStrip;
  final List<int> stripOffsets;
  final List<int> stripByteCounts;
  final int? tileWidth;
  final int? tileLength;
  final List<int>? tileOffsets;
  final List<int>? tileByteCounts;
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
    required this.predictor,
    required this.photometric,
    required this.planarConfiguration,
    required this.rowsPerStrip,
    required this.stripOffsets,
    required this.stripByteCounts,
    required this.tileWidth,
    required this.tileLength,
    required this.tileOffsets,
    required this.tileByteCounts,
    required this.colorMap,
    required this.rawTags,
  });

  bool get isTiled => tileOffsets != null;

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
    final predictor = tags[TiffTagId.predictor]?.asInt() ?? 1;

    final photometricCode = tags[TiffTagId.photometricInterpretation]?.asInt();
    final photometric = photometricCode == null ? null : TiffPhotometric.fromCode(photometricCode);

    final planarConfiguration =
        TiffPlanarConfiguration.fromCode(tags[TiffTagId.planarConfiguration]?.asInt() ?? 1);
    final colorMap = tags[TiffTagId.colorMap]?.asIntList();

    final stripOffsetsTag = tags[TiffTagId.stripOffsets];
    final stripByteCountsTag = tags[TiffTagId.stripByteCounts];
    if (stripOffsetsTag != null && stripByteCountsTag != null) {
      return TiffImageMetadata(
        width: width,
        height: height,
        bitsPerSample: bitsPerSample,
        samplesPerPixel: samplesPerPixel,
        compression: compression,
        predictor: predictor,
        photometric: photometric,
        planarConfiguration: planarConfiguration,
        rowsPerStrip: tags[TiffTagId.rowsPerStrip]?.asInt() ?? height,
        stripOffsets: stripOffsetsTag.asIntList(),
        stripByteCounts: stripByteCountsTag.asIntList(),
        tileWidth: null,
        tileLength: null,
        tileOffsets: null,
        tileByteCounts: null,
        colorMap: colorMap,
        rawTags: tags,
      );
    }

    final tileOffsetsTag = tags[TiffTagId.tileOffsets];
    final tileByteCountsTag = tags[TiffTagId.tileByteCounts];
    if (tileOffsetsTag != null && tileByteCountsTag != null) {
      return TiffImageMetadata(
        width: width,
        height: height,
        bitsPerSample: bitsPerSample,
        samplesPerPixel: samplesPerPixel,
        compression: compression,
        predictor: predictor,
        photometric: photometric,
        planarConfiguration: planarConfiguration,
        rowsPerStrip: height,
        stripOffsets: const [],
        stripByteCounts: const [],
        tileWidth: requireInt(TiffTagId.tileWidth, 'TileWidth'),
        tileLength: requireInt(TiffTagId.tileLength, 'TileLength'),
        tileOffsets: tileOffsetsTag.asIntList(),
        tileByteCounts: tileByteCountsTag.asIntList(),
        colorMap: colorMap,
        rawTags: tags,
      );
    }

    throw const TiffException('Missing pixel data location tags (StripOffsets or TileOffsets)');
  }
}
