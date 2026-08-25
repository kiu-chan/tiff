import 'dart:typed_data';

/// PackBits (Compression 32773): a simple byte-oriented run-length scheme.
///
/// Each control byte `n` is followed by either a literal run or a repeat:
/// - `n` in [0, 127]: copy the next `n + 1` bytes literally.
/// - `n` in [-127, -1]: repeat the next single byte `1 - n` times.
/// - `n == -128`: no-op (some encoders emit this as padding).
class PackBitsCodec {
  const PackBitsCodec._();

  static Uint8List decode(Uint8List input) {
    final output = BytesBuilder();
    var i = 0;
    while (i < input.length) {
      final n = input[i].toSigned(8);
      i++;
      if (n >= 0) {
        final count = n + 1;
        output.add(input.sublist(i, i + count));
        i += count;
      } else if (n != -128) {
        final count = 1 - n;
        final byte = input[i];
        i++;
        output.add(List.filled(count, byte));
      }
    }
    return output.toBytes();
  }

  static Uint8List encode(Uint8List input) {
    final output = BytesBuilder();
    final n = input.length;
    var i = 0;
    while (i < n) {
      var runLength = 1;
      while (i + runLength < n && input[i + runLength] == input[i] && runLength < 128) {
        runLength++;
      }
      if (runLength >= 2) {
        output.addByte((-(runLength - 1)) & 0xFF);
        output.addByte(input[i]);
        i += runLength;
        continue;
      }

      final literalStart = i;
      var literalLength = 1;
      i++;
      while (i < n && literalLength < 128) {
        var nextRunLength = 1;
        while (i + nextRunLength < n && input[i + nextRunLength] == input[i] && nextRunLength < 128) {
          nextRunLength++;
        }
        if (nextRunLength >= 2) break;
        literalLength++;
        i++;
      }
      output.addByte(literalLength - 1);
      output.add(input.sublist(literalStart, literalStart + literalLength));
    }
    return output.toBytes();
  }
}
