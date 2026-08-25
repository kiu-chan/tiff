import 'dart:typed_data';

import '../tiff_exception.dart';

const int _clearCode = 256;
const int _eoiCode = 257;
const int _firstCode = 258;
const int _maxCode = 4096;

/// TIFF-flavored LZW (Compression 5).
///
/// Same core dictionary algorithm as GIF/Unix `compress`, but codes are
/// packed **MSB-first** (GIF is LSB-first), and code width grows one code
/// early ("early change"): 9-bit codes cover 0-510 (not 0-511), 10-bit
/// covers 511-1022, etc. This off-by-one originates from the original TIFF
/// LZW implementation and has been the de facto standard ever since — every
/// modern encoder (libtiff, Photoshop, GDAL, ...) relies on it.
///
/// [decode] also transparently handles "old-style" LZW — a handful of
/// pre-TIFF6 encoders packed codes LSB-first with no early change; real
/// files in the wild still use it, and libtiff itself special-cases it
/// (`LZW_COMPAT`). It's auto-detected, never something a caller opts into.
///
/// [encode] exists mainly so the decoder can be verified by round-trip in
/// tests; it is a correct, self-consistent LZW encoder but does not attempt
/// to bit-match any particular external encoder's table-reset heuristics,
/// and it only ever writes the standard (not old-style) packing.
class LzwCodec {
  const LzwCodec._();

  static Uint8List decode(Uint8List input) {
    // A small, long-lived compatibility wrinkle: some old TIFF encoders
    // (pre-dating the spec settling on MSB-first packing) wrote codes
    // LSB-first instead, with no "early change" bit-width bump. A
    // conformant stream's first code is always the 256 (Clear) code, so
    // detecting which packing produced these bytes is unambiguous — under
    // LSB-first packing, 256's low 8 bits (all zero) land entirely in byte
    // 0 and its 9th bit lands as bit 0 of byte 1. This is the same
    // heuristic libtiff itself uses (LZWPreDecode's "old bit-reversed
    // codes" check).
    final isOldStyle =
        input.length >= 2 && input[0] == 0 && (input[1] & 0x1) != 0;
    return isOldStyle
        ? _decodeCore(_LzwBitReaderLsb(input), earlyChange: false)
        : _decodeCore(_LzwBitReaderMsb(input), earlyChange: true);
  }

  static Uint8List _decodeCore(
    _LzwBitReader reader, {
    required bool earlyChange,
  }) {
    final output = BytesBuilder();
    var table = _newTable();
    var nextCode = _firstCode;
    var bitWidth = 9;
    List<int>? oldEntry;

    var code = reader.readBits(bitWidth);
    while (code != null && code != _eoiCode) {
      if (code == _clearCode) {
        table = _newTable();
        nextCode = _firstCode;
        bitWidth = 9;
        oldEntry = null;
        code = reader.readBits(bitWidth);
        continue;
      }

      final List<int> entry;
      if (code < nextCode && table[code] != null) {
        entry = table[code]!;
      } else if (code == nextCode && oldEntry != null) {
        entry = [...oldEntry, oldEntry.first];
      } else {
        throw TiffException('Invalid LZW code: $code');
      }

      output.add(entry);

      if (oldEntry != null && nextCode < _maxCode) {
        table[nextCode] = [...oldEntry, entry.first];
        nextCode++;
        final maxCodeForWidth = (1 << bitWidth) - (earlyChange ? 2 : 1);
        if (nextCode > maxCodeForWidth && bitWidth < 12) bitWidth++;
      }

      oldEntry = entry;
      code = reader.readBits(bitWidth);
    }

    return output.toBytes();
  }

  static Uint8List encode(Uint8List input) {
    if (input.isEmpty) return Uint8List(0);

    final writer = _LzwBitWriter();
    var bitWidth = 9;
    var nextCode = _firstCode;
    var table = <String, int>{
      for (var i = 0; i < 256; i++) String.fromCharCode(i): i,
    };

    // A decoder only learns of a new dictionary entry while decoding the
    // code *after* the one that revealed it (it needs that code's first
    // byte to complete the entry), so its code-width bumps land one
    // transmitted code later than the encoder's own bookkeeping would
    // naively suggest. `scheduledWidth`/`scheduledDelay` reproduce that
    // one-code lag here so the two stay in lockstep.
    int? scheduledWidth;
    var scheduledDelay = 0;

    void write(int code) {
      if (scheduledWidth != null) {
        if (scheduledDelay > 0) {
          scheduledDelay--;
        } else {
          bitWidth = scheduledWidth!;
          scheduledWidth = null;
        }
      }
      writer.writeBits(code, bitWidth);
    }

    write(_clearCode);
    var current = String.fromCharCode(input[0]);
    for (var i = 1; i < input.length; i++) {
      final next = current + String.fromCharCode(input[i]);
      if (table.containsKey(next)) {
        current = next;
        continue;
      }

      write(table[current]!);
      if (nextCode >= _maxCode) {
        write(_clearCode);
        table = {for (var i = 0; i < 256; i++) String.fromCharCode(i): i};
        nextCode = _firstCode;
        bitWidth = 9;
        scheduledWidth = null;
        scheduledDelay = 0;
      } else {
        table[next] = nextCode;
        nextCode++;
        final maxCodeForWidth = (1 << bitWidth) - 2;
        if (nextCode > maxCodeForWidth &&
            bitWidth < 12 &&
            scheduledWidth == null) {
          scheduledWidth = bitWidth + 1;
          scheduledDelay = 1;
        }
      }
      current = String.fromCharCode(input[i]);
    }
    write(table[current]!);
    write(_eoiCode);
    return writer.toBytes();
  }

  static List<List<int>?> _newTable() {
    final table = List<List<int>?>.filled(_maxCode, null);
    for (var i = 0; i < 256; i++) {
      table[i] = [i];
    }
    return table;
  }
}

/// Reads a fixed number of bits at a time from a byte buffer — either
/// MSB-first (the TIFF 6.0 standard) or LSB-first (see [LzwCodec.decode]'s
/// "old-style" compatibility handling).
abstract class _LzwBitReader {
  int? readBits(int n);
}

/// MSB-first bit reader: the TIFF 6.0 standard packing.
class _LzwBitReaderMsb implements _LzwBitReader {
  final Uint8List data;
  int _bytePos = 0;
  int _bitBuffer = 0;
  int _bitCount = 0;

  _LzwBitReaderMsb(this.data);

  @override
  int? readBits(int n) {
    while (_bitCount < n) {
      if (_bytePos >= data.length) {
        return null;
      }
      _bitBuffer = (_bitBuffer << 8) | data[_bytePos++];
      _bitCount += 8;
    }
    final shift = _bitCount - n;
    final value = (_bitBuffer >> shift) & ((1 << n) - 1);
    _bitCount -= n;
    _bitBuffer &= (1 << _bitCount) - 1;
    return value;
  }
}

/// LSB-first bit reader, for "old-style" LZW data (a handful of TIFF
/// encoders predating the spec settling on MSB-first packing). Ported from
/// libtiff's `GetNextCodeCompat` macro.
class _LzwBitReaderLsb implements _LzwBitReader {
  final Uint8List data;
  int _bytePos = 0;
  int _bitBuffer = 0;
  int _bitCount = 0;

  _LzwBitReaderLsb(this.data);

  @override
  int? readBits(int n) {
    while (_bitCount < n) {
      if (_bytePos >= data.length) {
        return null;
      }
      _bitBuffer |= data[_bytePos++] << _bitCount;
      _bitCount += 8;
    }
    final value = _bitBuffer & ((1 << n) - 1);
    _bitBuffer >>= n;
    _bitCount -= n;
    return value;
  }
}

/// Writes a fixed number of bits at a time, MSB-first, into a byte buffer.
class _LzwBitWriter {
  final List<int> _bytes = [];
  int _bitBuffer = 0;
  int _bitCount = 0;

  void writeBits(int value, int nbits) {
    _bitBuffer = (_bitBuffer << nbits) | (value & ((1 << nbits) - 1));
    _bitCount += nbits;
    while (_bitCount >= 8) {
      final shift = _bitCount - 8;
      _bytes.add((_bitBuffer >> shift) & 0xFF);
      _bitCount -= 8;
      _bitBuffer &= (1 << _bitCount) - 1;
    }
  }

  Uint8List toBytes() {
    if (_bitCount > 0) {
      _bytes.add((_bitBuffer << (8 - _bitCount)) & 0xFF);
      _bitCount = 0;
      _bitBuffer = 0;
    }
    return Uint8List.fromList(_bytes);
  }
}
