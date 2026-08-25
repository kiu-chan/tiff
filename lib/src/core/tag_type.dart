/// TIFF/BigTIFF tag value types (TIFF 6.0 §2, plus the BigTIFF extensions
/// LONG8/SLONG8/IFD8 for 64-bit values and IFD pointers).
enum TiffTagType {
  tByte(1, 1),
  tAscii(2, 1),
  tShort(3, 2),
  tLong(4, 4),
  tRational(5, 8),
  tSbyte(6, 1),
  tUndefined(7, 1),
  tSshort(8, 2),
  tSlong(9, 4),
  tSrational(10, 8),
  tFloat(11, 4),
  tDouble(12, 8),
  tIfd(13, 4),
  tLong8(16, 8),
  tSlong8(17, 8),
  tIfd8(18, 8);

  /// Numeric type code as stored in an IFD entry.
  final int code;

  /// Size in bytes of a single component of this type.
  final int byteSize;

  const TiffTagType(this.code, this.byteSize);

  static TiffTagType? fromCode(int code) {
    for (final type in values) {
      if (type.code == code) return type;
    }
    return null;
  }
}
