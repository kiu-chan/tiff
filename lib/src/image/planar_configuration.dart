/// PlanarConfiguration (tag 284): how samples of a pixel are arranged.
enum TiffPlanarConfiguration {
  /// Chunky/interleaved: R,G,B,R,G,B,... (the common case).
  chunky(1),

  /// Planar: all R values, then all G values, then all B values.
  planar(2);

  final int code;

  const TiffPlanarConfiguration(this.code);

  static TiffPlanarConfiguration fromCode(int code) => code == 2 ? planar : chunky;
}
