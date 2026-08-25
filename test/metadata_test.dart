import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

import 'support/tiff_fixture_builder.dart';

void _addMinimalImageTags(TiffFixtureBuilder builder) {
  builder
    ..addTag(TiffTagId.imageWidth, TiffTagType.tShort, [2])
    ..addTag(TiffTagId.imageLength, TiffTagType.tShort, [2])
    ..addTag(TiffTagId.bitsPerSample, TiffTagType.tShort, [8])
    ..addTag(TiffTagId.samplesPerPixel, TiffTagType.tShort, [1])
    ..addTag(TiffTagId.compression, TiffTagType.tShort, [1])
    ..addTag(TiffTagId.photometricInterpretation, TiffTagType.tShort, [1])
    ..addStripOffsetsTag(TiffTagId.stripOffsets, TiffTagType.tLong, [4])
    ..addTag(TiffTagId.stripByteCounts, TiffTagType.tLong, [4])
    ..setPixelData(Uint8List.fromList([1, 2, 3, 4]));
}

void main() {
  group('GeoTIFF metadata', () {
    test('is null when no GeoTIFF tags are present', () {
      final builder = TiffFixtureBuilder();
      _addMinimalImageTags(builder);
      final doc = TiffDecoder.decode(builder.build());
      expect(doc.images.single.metadata.geoTiff, isNull);
    });

    test('parses ModelPixelScale, ModelTiepoint, and GeoKeyDirectory', () {
      final builder = TiffFixtureBuilder();
      _addMinimalImageTags(builder);
      builder
        ..addDoubleTag(TiffTagId.modelPixelScale, [2.0, 2.0, 0.0])
        ..addDoubleTag(TiffTagId.modelTiepoint, [
          0.0,
          0.0,
          0.0,
          500000.0,
          4000000.0,
          0.0,
        ])
        ..addAsciiTag(TiffTagId.geoAsciiParams, 'WGS 84|')
        ..addTag(TiffTagId.geoKeyDirectory, TiffTagType.tShort, [
          1, 1, 0, 2, // header: version 1.1.0, 2 keys
          GeoTiffKeyId.gtModelType, 0, 1, GeoTiffModelType.projected,
          GeoTiffKeyId.pcsCitation, TiffTagId.geoAsciiParams, 7, 0,
        ]);

      final doc = TiffDecoder.decode(builder.build());
      final geo = doc.images.single.metadata.geoTiff;
      expect(geo, isNotNull);
      expect(geo!.modelPixelScale, [2.0, 2.0, 0.0]);
      expect(geo.modelTiepoints, hasLength(1));
      expect(geo.modelTiepoints.single.modelX, 500000.0);
      expect(geo.modelTiepoints.single.modelY, 4000000.0);
      expect(geo.geoKeys[GeoTiffKeyId.gtModelType], GeoTiffModelType.projected);
      expect(geo.geoKeys[GeoTiffKeyId.pcsCitation], 'WGS 84');
    });

    test('parses ModelTransformation', () {
      final builder = TiffFixtureBuilder();
      _addMinimalImageTags(builder);
      final matrix = List<double>.generate(16, (i) => i.toDouble());
      builder.addDoubleTag(TiffTagId.modelTransformation, matrix);

      final doc = TiffDecoder.decode(builder.build());
      final geo = doc.images.single.metadata.geoTiff;
      expect(geo!.modelTransformation, matrix);
    });
  });

  group('EXIF/GPS sub-IFDs', () {
    test('are null when absent', () {
      final builder = TiffFixtureBuilder();
      _addMinimalImageTags(builder);
      final doc = TiffDecoder.decode(builder.build());
      expect(doc.images.single.metadata.exifTags, isNull);
      expect(doc.images.single.metadata.gpsTags, isNull);
    });

    test('are resolved from their sub-IFD offset', () {
      final exifIfdOffset = 300;
      final builder = TiffFixtureBuilder();
      _addMinimalImageTags(builder);
      builder.addTag(TiffTagId.exifIfd, TiffTagType.tLong, [exifIfdOffset]);

      var bytes = builder.build();
      // Hand-append a minimal EXIF sub-IFD: 1 entry (ISOSpeedRatings=400),
      // no further chaining.
      final extra = Uint8List(2 + 12 + 4);
      final bd = ByteData.sublistView(extra);
      bd.setUint16(0, 1, Endian.little); // 1 entry
      bd.setUint16(2, ExifTagId.isoSpeedRatings, Endian.little);
      bd.setUint16(4, TiffTagType.tShort.code, Endian.little);
      bd.setUint32(6, 1, Endian.little);
      bd.setUint16(10, 400, Endian.little); // inline value
      bd.setUint32(14, 0, Endian.little); // next IFD offset

      if (exifIfdOffset + extra.length > bytes.length) {
        final grown = Uint8List(exifIfdOffset + extra.length);
        grown.setRange(0, bytes.length, bytes);
        bytes = grown;
      }
      bytes.setRange(exifIfdOffset, exifIfdOffset + extra.length, extra);

      final doc = TiffDecoder.decode(bytes);
      final exif = doc.images.single.metadata.exifTags;
      expect(exif, isNotNull);
      expect(exif![ExifTagId.isoSpeedRatings]!.asInt(), 400);
    });
  });
}
