import '../core/tag_value.dart';
import '../tags/tag_id.dart';

/// One entry of the ModelTiepointTag (33922): a raster point mapped to a
/// point in model (georeferenced) space.
class GeoTiffTiepoint {
  final double rasterX;
  final double rasterY;
  final double rasterZ;
  final double modelX;
  final double modelY;
  final double modelZ;

  const GeoTiffTiepoint({
    required this.rasterX,
    required this.rasterY,
    required this.rasterZ,
    required this.modelX,
    required this.modelY,
    required this.modelZ,
  });
}

/// GeoTIFF georeferencing metadata (the de facto standard for embedding a
/// coordinate reference system in a TIFF, predating and unrelated to the
/// TIFF 6.0 baseline spec). Not every raster has this — see
/// [TiffImageMetadata.geoTiff].
///
/// [geoKeys] holds every entry from the GeoKeyDirectory, resolved to its
/// actual value (an `int`, `double`, or `String` depending on where the
/// spec says that key's value lives), keyed by GeoKey ID — see
/// [GeoTiffKeyId] for the commonly-used IDs. Keys this class doesn't know
/// the name of are still present in the map under their raw numeric ID.
class GeoTiffMetadata {
  final List<double>? modelPixelScale;
  final List<GeoTiffTiepoint> modelTiepoints;
  final List<double>? modelTransformation;
  final Map<int, Object> geoKeys;

  const GeoTiffMetadata({
    required this.modelPixelScale,
    required this.modelTiepoints,
    required this.modelTransformation,
    required this.geoKeys,
  });

  /// Returns `null` when [tags] carries none of the GeoTIFF tags.
  static GeoTiffMetadata? fromTags(Map<int, TiffTagValue> tags) {
    final pixelScaleTag = tags[TiffTagId.modelPixelScale];
    final tiepointTag = tags[TiffTagId.modelTiepoint];
    final transformTag = tags[TiffTagId.modelTransformation];
    final keyDirTag = tags[TiffTagId.geoKeyDirectory];
    if (pixelScaleTag == null &&
        tiepointTag == null &&
        transformTag == null &&
        keyDirTag == null) {
      return null;
    }

    final tiepointValues = tiepointTag?.asDoubleList() ?? const <double>[];
    final tiepoints = <GeoTiffTiepoint>[];
    for (var i = 0; i + 5 < tiepointValues.length; i += 6) {
      tiepoints.add(
        GeoTiffTiepoint(
          rasterX: tiepointValues[i],
          rasterY: tiepointValues[i + 1],
          rasterZ: tiepointValues[i + 2],
          modelX: tiepointValues[i + 3],
          modelY: tiepointValues[i + 4],
          modelZ: tiepointValues[i + 5],
        ),
      );
    }

    final geoKeys = <int, Object>{};
    if (keyDirTag != null) {
      final dir = keyDirTag.asIntList();
      final doubleParams = tags[TiffTagId.geoDoubleParams]?.asDoubleList();
      final asciiParams = tags[TiffTagId.geoAsciiParams]?.asString();
      final numberOfKeys = dir.length >= 4 ? dir[3] : 0;
      for (var i = 0; i < numberOfKeys; i++) {
        final base = 4 + i * 4;
        if (base + 3 >= dir.length) break;
        final keyId = dir[base];
        final location = dir[base + 1];
        final count = dir[base + 2];
        final valueOrOffset = dir[base + 3];

        if (location == 0) {
          geoKeys[keyId] = valueOrOffset;
        } else if (location == TiffTagId.geoDoubleParams &&
            doubleParams != null) {
          if (valueOrOffset < doubleParams.length) {
            geoKeys[keyId] = doubleParams[valueOrOffset];
          }
        } else if (location == TiffTagId.geoAsciiParams &&
            asciiParams != null) {
          final end = (valueOrOffset + count).clamp(0, asciiParams.length);
          if (valueOrOffset < end) {
            var value = asciiParams.substring(valueOrOffset, end);
            if (value.endsWith('|')) {
              value = value.substring(0, value.length - 1);
            }
            geoKeys[keyId] = value;
          }
        }
      }
    }

    return GeoTiffMetadata(
      modelPixelScale: pixelScaleTag?.asDoubleList(),
      modelTiepoints: tiepoints,
      modelTransformation: transformTag?.asDoubleList(),
      geoKeys: geoKeys,
    );
  }
}
