import 'dart:typed_data';

/// Allocates a zero-filled, [length]-sample buffer sized for [bitsPerSample]
/// — the narrowest typed-data list that can hold every value that bit depth
/// allows (`Uint8List` for 8 bits or fewer, `Uint16List` for 9-16,
/// `Uint32List` above that), rather than a generic `List<int>`, which costs
/// a full 8-byte machine word per element in Dart regardless of how few bits
/// the value actually needs.
///
/// This is what makes [TiffChunkPlan]'s own per-pixel cost estimate (see its
/// `_bytesPerPixel`) match what a decode actually allocates — every
/// [TiffRasterBuffer.samples] and the equivalent intermediate buffer in
/// `ChunkDecoder.decodeChunk` are built with this, not `List<int>.filled`,
/// specifically so a memory budget computed from that estimate isn't handed
/// a buffer using 4-8x more memory than it was sized for. For a real
/// whole-slide-image page (8-bit RGB, JPEG-compressed), this is the
/// difference between ~28 bytes/pixel and ~7 — i.e. up to 4x more page can
/// be decoded in one aligned, tile/strip-height chunk within the same
/// budget, which is what lets that chunk stay tile-aligned (no redundant
/// redecode) and parallelize across more cores in the first place, instead
/// of a budget forcing chunks below the native tile/strip height purely
/// because of how the intermediate buffer happened to be represented rather
/// than how much data it actually holds.
List<int> allocateSampleBuffer(int bitsPerSample, int length) {
  if (bitsPerSample <= 8) return Uint8List(length);
  if (bitsPerSample <= 16) return Uint16List(length);
  return Uint32List(length);
}

/// Decoded, unpacked pixel data for one TIFF page: one integer sample per
/// channel per pixel, row-major, chunky/interleaved (channel varies fastest).
///
/// This is intentionally format-agnostic (no RGBA conversion, no photometric
/// interpretation applied) — that belongs to a separate color-transform step
/// so callers who want raw samples (e.g. 16-bit grayscale, palette indices)
/// aren't forced through an RGBA reinterpretation.
///
/// [samples] is built via [allocateSampleBuffer] — a typed-data list picked
/// by [bitsPerSample] — rather than a generic `List<int>`; see that
/// function's doc comment for why the distinction matters well beyond raw
/// memory use.
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

  int sampleAt(int x, int y, int channel) =>
      samples[(y * width + x) * samplesPerPixel + channel];
}
