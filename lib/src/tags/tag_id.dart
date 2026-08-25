/// Well-known baseline TIFF tag IDs (TIFF 6.0 §2-3).
///
/// Only the tags needed so far are listed here; extend this as later
/// phases add tile support, GeoTIFF, EXIF, etc. — keep it a flat table of
/// constants, no logic, so it stays trivial to grep and extend.
class TiffTagId {
  const TiffTagId._();

  static const int imageWidth = 256;
  static const int imageLength = 257;
  static const int bitsPerSample = 258;
  static const int compression = 259;
  static const int photometricInterpretation = 262;
  static const int imageDescription = 270;
  static const int stripOffsets = 273;
  static const int orientation = 274;
  static const int samplesPerPixel = 277;
  static const int rowsPerStrip = 278;
  static const int stripByteCounts = 279;
  static const int xResolution = 282;
  static const int yResolution = 283;
  static const int planarConfiguration = 284;
  static const int t4Options = 292;
  static const int t6Options = 293;
  static const int resolutionUnit = 296;
  static const int predictor = 317;
  static const int colorMap = 320;
  static const int tileWidth = 322;
  static const int tileLength = 323;
  static const int tileOffsets = 324;
  static const int tileByteCounts = 325;
  static const int extraSamples = 338;
  static const int sampleFormat = 339;
  static const int jpegTables = 347;
  static const int yCbCrSubSampling = 530;

  // GeoTIFF (not part of baseline TIFF 6.0, but a de facto standard).
  static const int modelPixelScale = 33550;
  static const int modelTiepoint = 33922;
  static const int modelTransformation = 34264;
  static const int geoKeyDirectory = 34735;
  static const int geoDoubleParams = 34736;
  static const int geoAsciiParams = 34737;

  // EXIF/GPS sub-IFD pointers.
  static const int exifIfd = 34665;
  static const int gpsInfoIfd = 34853;
}
