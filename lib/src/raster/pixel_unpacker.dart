import 'dart:typed_data';

import 'raster_buffer.dart';

/// Unpacks a row of raw, bit-packed sample data into one integer per sample.
///
/// Byte-aligned depths (8/16/32-bit) use a fast typed-data path. Anything
/// else (1/2/4-bit, and non-power-of-two depths some cameras use, e.g.
/// 12-bit) falls back to a generic MSB-first bit reader — TIFF packs samples
/// most-significant-bit first (FillOrder 1, the default and by far the
/// common case; FillOrder 2 is not handled here).
class PixelUnpacker {
  const PixelUnpacker._();

  static List<int> unpackRow({
    required Uint8List rowBytes,
    required int bitsPerSample,
    required int sampleCount,
    required Endian endian,
  }) {
    if (bitsPerSample % 8 == 0 && bitsPerSample <= 32) {
      final byteWidth = bitsPerSample ~/ 8;

      // 8-bit is the by far most common depth, and needs no per-sample
      // unpacking at all — rowBytes already *is* one byte per sample, so a
      // bulk copy replaces what would otherwise be a ByteData.getUint8 call
      // (with its own bounds/type check) for every single byte.
      if (byteWidth == 1) {
        final out = Uint8List(sampleCount);
        out.setRange(0, sampleCount, rowBytes);
        return out;
      }

      final data = ByteData.sublistView(rowBytes);
      final out = allocateSampleBuffer(bitsPerSample, sampleCount);
      for (var i = 0; i < sampleCount; i++) {
        final off = i * byteWidth;
        switch (byteWidth) {
          case 2:
            out[i] = data.getUint16(off, endian);
            break;
          case 3:
            out[i] = endian == Endian.little
                ? data.getUint8(off) |
                      (data.getUint8(off + 1) << 8) |
                      (data.getUint8(off + 2) << 16)
                : (data.getUint8(off) << 16) |
                      (data.getUint8(off + 1) << 8) |
                      data.getUint8(off + 2);
            break;
          case 4:
            out[i] = data.getUint32(off, endian);
            break;
        }
      }
      return out;
    }

    final out = List<int>.filled(sampleCount, 0);
    var bitPos = 0;
    for (var i = 0; i < sampleCount; i++) {
      var value = 0;
      for (var b = 0; b < bitsPerSample; b++) {
        final byteIndex = bitPos ~/ 8;
        final bitIndex = 7 - (bitPos % 8);
        final bit = (rowBytes[byteIndex] >> bitIndex) & 0x1;
        value = (value << 1) | bit;
        bitPos++;
      }
      out[i] = value;
    }
    return out;
  }
}
