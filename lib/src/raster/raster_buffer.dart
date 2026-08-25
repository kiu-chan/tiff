/// Decoded, unpacked pixel data for one TIFF page: one integer sample per
/// channel per pixel, row-major, chunky/interleaved (channel varies fastest).
///
/// This is intentionally format-agnostic (no RGBA conversion, no photometric
/// interpretation applied) — that belongs to a separate color-transform step
/// so callers who want raw samples (e.g. 16-bit grayscale, palette indices)
/// aren't forced through an RGBA reinterpretation.
class TiffRasterBuffer {
  final int width;
  final int height;
  final int samplesPerPixel;
  final int bitsPerSample;

  /// Length is `width * height * samplesPerPixel`.
  final List<int> samples;

  const TiffRasterBuffer({
    required this.width,
    required this.height,
    required this.samplesPerPixel,
    required this.bitsPerSample,
    required this.samples,
  });

  int sampleAt(int x, int y, int channel) => samples[(y * width + x) * samplesPerPixel + channel];
}
