/// Common tag IDs found in the EXIF sub-IFD (pointed to by baseline tag
/// 34665) — not exhaustive, just the fields most images actually carry.
/// Anything else is still readable via [TiffImageMetadata.exifTags]' raw
/// numeric keys.
class ExifTagId {
  const ExifTagId._();

  static const int exposureTime = 33434;
  static const int fNumber = 33437;
  static const int isoSpeedRatings = 34855;
  static const int dateTimeOriginal = 36867;
  static const int dateTimeDigitized = 36868;
  static const int shutterSpeedValue = 37377;
  static const int apertureValue = 37378;
  static const int exposureBiasValue = 37380;
  static const int meteringMode = 37383;
  static const int flash = 37385;
  static const int focalLength = 37386;
  static const int colorSpace = 40961;
  static const int pixelXDimension = 40962;
  static const int pixelYDimension = 40963;
  static const int focalLengthIn35mmFilm = 41989;
  static const int lensMake = 42035;
  static const int lensModel = 42036;
}

/// Common tag IDs in the GPS sub-IFD (pointed to by baseline tag 34853).
class GpsTagId {
  const GpsTagId._();

  static const int latitudeRef = 1;
  static const int latitude = 2;
  static const int longitudeRef = 3;
  static const int longitude = 4;
  static const int altitudeRef = 5;
  static const int altitude = 6;
  static const int timeStamp = 7;
  static const int dateStamp = 29;
}
