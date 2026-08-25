import 'dart:typed_data';

/// The write-side inverse of [PixelUnpacker](pixel_unpacker.dart): packs one
/// row of integer samples into bit-packed bytes.
///
/// Byte-aligned depths (8/16/32-bit) use a fast typed-data path; anything
/// else (1/2/4-bit, or a non-power-of-two depth) packs bits MSB-first,
/// matching how TIFF readers (this one included) expect them.
class PixelPacker {
  const PixelPacker._();

  static Uint8List packRow({
    required List<int> samples,
    required int bitsPerSample,
    required Endian endian,
  }) {
    if (bitsPerSample % 8 == 0 && bitsPerSample <= 32) {
      final byteWidth = bitsPerSample ~/ 8;
      final out = Uint8List(samples.length * byteWidth);
      final data = ByteData.sublistView(out);
      for (var i = 0; i < samples.length; i++) {
        final off = i * byteWidth;
        switch (byteWidth) {
          case 1:
            data.setUint8(off, samples[i]);
            break;
          case 2:
            data.setUint16(off, samples[i], endian);
            break;
          case 3:
            if (endian == Endian.little) {
              data.setUint8(off, samples[i] & 0xFF);
              data.setUint8(off + 1, (samples[i] >> 8) & 0xFF);
              data.setUint8(off + 2, (samples[i] >> 16) & 0xFF);
            } else {
              data.setUint8(off, (samples[i] >> 16) & 0xFF);
              data.setUint8(off + 1, (samples[i] >> 8) & 0xFF);
              data.setUint8(off + 2, samples[i] & 0xFF);
            }
            break;
          case 4:
            data.setUint32(off, samples[i], endian);
            break;
        }
      }
      return out;
    }

    final totalBits = samples.length * bitsPerSample;
    final out = Uint8List((totalBits + 7) ~/ 8);
    var bitPos = 0;
    for (final sample in samples) {
      for (var b = bitsPerSample - 1; b >= 0; b--) {
        final bit = (sample >> b) & 0x1;
        if (bit != 0) {
          final byteIndex = bitPos ~/ 8;
          final bitIndex = 7 - (bitPos % 8);
          out[byteIndex] |= 1 << bitIndex;
        }
        bitPos++;
      }
    }
    return out;
  }
}
