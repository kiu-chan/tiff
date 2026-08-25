/// Common GeoTIFF GeoKey IDs (the GeoTIFF spec defines many more — this
/// covers the ones most images actually set, enough to read a raster's
/// coordinate reference system without needing a full GeoKey registry).
class GeoTiffKeyId {
  const GeoTiffKeyId._();

  static const int gtModelType = 1024;
  static const int gtRasterType = 1025;
  static const int gtCitation = 1026;
  static const int geographicType = 2048;
  static const int geogCitation = 2049;
  static const int geogAngularUnits = 2054;
  static const int projectedCsType = 3072;
  static const int pcsCitation = 3073;
  static const int projection = 3074;
  static const int projCoordTrans = 3075;
  static const int projLinearUnits = 3076;
  static const int verticalCsType = 4096;
  static const int verticalCitation = 4097;
  static const int verticalUnits = 4099;
}

/// `GTModelTypeGeoKey` (1024) values.
class GeoTiffModelType {
  const GeoTiffModelType._();

  static const int projected = 1;
  static const int geographic = 2;
  static const int geocentric = 3;
}
