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
  static const int resolutionUnit = 296;
  static const int predictor = 317;
  static const int colorMap = 320;
  static const int tileWidth = 322;
  static const int tileLength = 323;
  static const int tileOffsets = 324;
  static const int tileByteCounts = 325;
  static const int extraSamples = 338;
  static const int sampleFormat = 339;
  static const int yCbCrSubSampling = 530;
}
