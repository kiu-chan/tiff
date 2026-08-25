/// Compression (tag 259) codes defined by TIFF 6.0 and its common extensions.
enum TiffCompressionType {
  none(1),
  ccittRle(2),
  ccittFax3(3),
  ccittFax4(4),
  lzw(5),
  oldJpeg(6),
  jpeg(7),
  deflateAdobe(8),
  packBits(32773),
  deflateZip(32946);

  final int code;

  const TiffCompressionType(this.code);

  static TiffCompressionType? fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}
