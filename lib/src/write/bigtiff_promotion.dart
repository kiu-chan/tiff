/// Decides whether a file being written needs BigTIFF's 64-bit offsets.
class BigTiffPromotion {
  const BigTiffPromotion._();

  /// Classic TIFF offsets are 32-bit, so anything at or beyond 4 GiB can't
  /// be addressed. Leaves a margin below the hard limit for header/IFD
  /// overhead, which is negligible next to the multi-gigabyte pixel data
  /// that would actually trigger this.
  static const int classicOffsetLimit = 0xFFFFFFFF;
  static const int _safetyMargin = 16 * 1024 * 1024;

  static bool shouldUseBigTiff({required int totalPixelDataBytes, bool? forceBigTiff}) {
    if (forceBigTiff != null) return forceBigTiff;
    return totalPixelDataBytes > classicOffsetLimit - _safetyMargin;
  }
}
