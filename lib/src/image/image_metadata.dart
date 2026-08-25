import 'dart:typed_data';

import '../core/byte_reader.dart';
import '../core/ifd/ifd_reader.dart';
import '../core/tag_value.dart';
import '../metadata/geotiff_metadata.dart';
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

  /// GeoTIFF georeferencing metadata, if this page has any — see
  /// [GeoTiffMetadata].
  final GeoTiffMetadata? geoTiff;

  /// Resolved tags from the EXIF sub-IFD (tag 34665), if present — see
  /// [ExifTagId] for common tag IDs.
  final Map<int, TiffTagValue>? exifTags;

  /// Resolved tags from the GPS sub-IFD (tag 34853), if present — see
  /// [GpsTagId] for common tag IDs.
  final Map<int, TiffTagValue>? gpsTags;

  /// Every tag found in this page's IFD, resolved but unfiltered — use this
  /// for tags not modeled above (ImageDescription, ...).
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
    required this.geoTiff,
    required this.exifTags,
    required this.gpsTags,
    required this.rawTags,
  });

  bool get isTiled => tileOffsets != null;

  /// T4Options (tag 292) — only meaningful when [compression] is 3.
  int get t4Options => rawTags[TiffTagId.t4Options]?.asInt() ?? 0;

  /// T6Options (tag 293) — only meaningful when [compression] is 4.
  int get t6Options => rawTags[TiffTagId.t6Options]?.asInt() ?? 0;

  /// JPEGTables (tag 347) — shared quantization/Huffman tables prepended to
  /// each strip/tile's "abbreviated" JPEG stream, when [compression] is 6
  /// or 7 and the encoder chose to share tables across strips.
  Uint8List? get jpegTables {
    final ints = rawTags[TiffTagId.jpegTables]?.asIntList();
    return ints == null ? null : Uint8List.fromList(ints);
  }

  /// [reader]/[isBigTiff] are only needed to resolve the EXIF/GPS sub-IFDs
  /// (tags 34665/34853, each just an offset to another IFD elsewhere in the
  /// file) — pass `null` to skip that (GeoTIFF and every other tag are
  /// already fully resolved in [tags] and don't need it).
  factory TiffImageMetadata.fromTags(
    Map<int, TiffTagValue> tags, {
    TiffByteReader? reader,
    bool isBigTiff = false,
  }) {
    int requireInt(int tagId, String name) {
      final value = tags[tagId];
      if (value == null) {
        throw TiffException('Missing required tag $name ($tagId)');
      }
      return value.asInt();
    }

    Map<int, TiffTagValue>? readSubIfd(int pointerTagId) {
      final offset = tags[pointerTagId]?.asInt();
      if (offset == null || reader == null) return null;
      final result = TiffIfdReader.read(reader, offset, isBigTiff: isBigTiff);
      return {
        for (final entry in result.entries)
          entry.tagId: TiffIfdReader.resolveValue(
            reader,
            entry,
            isBigTiff: isBigTiff,
          ),
      };
    }

    final geoTiff = GeoTiffMetadata.fromTags(tags);
    final exifTags = readSubIfd(TiffTagId.exifIfd);
    final gpsTags = readSubIfd(TiffTagId.gpsInfoIfd);

    final width = requireInt(TiffTagId.imageWidth, 'ImageWidth');
    final height = requireInt(TiffTagId.imageLength, 'ImageLength');
    final samplesPerPixel = tags[TiffTagId.samplesPerPixel]?.asInt() ?? 1;
    final bitsPerSample =
        tags[TiffTagId.bitsPerSample]?.asIntList() ??
        List.filled(samplesPerPixel, 1);
    final compression = tags[TiffTagId.compression]?.asInt() ?? 1;
    final predictor = tags[TiffTagId.predictor]?.asInt() ?? 1;

    final photometricCode = tags[TiffTagId.photometricInterpretation]?.asInt();
    final photometric = photometricCode == null
        ? null
        : TiffPhotometric.fromCode(photometricCode);

    final planarConfiguration = TiffPlanarConfiguration.fromCode(
      tags[TiffTagId.planarConfiguration]?.asInt() ?? 1,
    );
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
        geoTiff: geoTiff,
        exifTags: exifTags,
        gpsTags: gpsTags,
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
        geoTiff: geoTiff,
        exifTags: exifTags,
        gpsTags: gpsTags,
        rawTags: tags,
      );
    }

    throw const TiffException(
      'Missing pixel data location tags (StripOffsets or TileOffsets)',
    );
  }
}
