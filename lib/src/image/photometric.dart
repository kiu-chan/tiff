/// PhotometricInterpretation (tag 262): how sample values map to color.
enum TiffPhotometric {
  whiteIsZero(0),
  blackIsZero(1),
  rgb(2),
  palette(3),
  transparencyMask(4),
  cmyk(5),
  ycbcr(6),
  cielab(8);

  final int code;

  const TiffPhotometric(this.code);

  static TiffPhotometric? fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}
