import 'dart:typed_data';

import 'package:tiff/tiff.dart';

/// Hand-rolled TIFF/BigTIFF byte builder used only by tests, to validate the
/// decoder against exact, known-good byte layouts without shipping binary
/// fixture files. Supports SHORT/LONG tags (all Phase 1 baseline tags use
/// one of these) with automatic inline-vs-overflow placement, matching the
/// real format's rules.
class TiffFixtureBuilder {
  final bool bigTiff;
  final Endian endian;
  final List<_Tag> _tags = [];
  Uint8List _pixelData = Uint8List(0);

  TiffFixtureBuilder({this.bigTiff = false, this.endian = Endian.little});

  void addTag(int id, TiffTagType type, List<int> values) {
    _tags.add(_Tag(id, type, values));
  }

  void addDoubleTag(int id, List<double> values) {
    _tags.add(
      _Tag(
        id,
        TiffTagType.tDouble,
        List.filled(values.length, 0),
        doubleValues: values,
      ),
    );
  }

  void addAsciiTag(int id, String value) {
    _tags.add(
      _Tag(
        id,
        TiffTagType.tAscii,
        List.filled(value.length + 1, 0),
        asciiValue: value,
      ),
    );
  }

  /// Adds a StripOffsets/TileOffsets tag whose values are computed
  /// automatically from [byteCounts] (one entry per strip/tile) once the
  /// pixel data location is known, so callers don't need to hand-compute
  /// absolute file offsets.
  void addStripOffsetsTag(int id, TiffTagType type, List<int> byteCounts) {
    _tags.add(
      _Tag(
        id,
        type,
        List.filled(byteCounts.length, 0),
        stripByteCounts: byteCounts,
      ),
    );
  }

  void addTileOffsetsTag(int id, TiffTagType type, List<int> byteCounts) =>
      addStripOffsetsTag(id, type, byteCounts);

  void setPixelData(Uint8List data) => _pixelData = data;

  Uint8List build() {
    final tags = List<_Tag>.from(_tags)..sort((a, b) => a.id.compareTo(b.id));
    final entrySize = bigTiff ? 20 : 12;
    final inlineLimit = bigTiff ? 8 : 4;
    final headerSize = bigTiff ? 16 : 8;
    final countFieldSize = bigTiff ? 8 : 2;
    final nextIfdFieldSize = bigTiff ? 8 : 4;

    final ifdStart = headerSize;
    final ifdEnd =
        ifdStart + countFieldSize + tags.length * entrySize + nextIfdFieldSize;

    final valueBytesList = <Uint8List>[];
    final overflowOffsets = <int?>[];
    var overflowCursor = ifdEnd;
    for (final tag in tags) {
      final bytes = _encodeTag(tag);
      valueBytesList.add(bytes);
      if (bytes.length > inlineLimit) {
        overflowOffsets.add(overflowCursor);
        overflowCursor += bytes.length;
        if (overflowCursor.isOdd) overflowCursor++;
      } else {
        overflowOffsets.add(null);
      }
    }

    final pixelDataOffset = overflowCursor;

    for (var i = 0; i < tags.length; i++) {
      final counts = tags[i].stripByteCounts;
      if (counts != null) {
        var cumulative = pixelDataOffset;
        final resolved = <int>[];
        for (final count in counts) {
          resolved.add(cumulative);
          cumulative += count;
        }
        valueBytesList[i] = _encodeValues(tags[i].type, resolved);
      }
    }

    final totalSize = pixelDataOffset + _pixelData.length;
    final out = Uint8List(totalSize);
    final data = ByteData.sublistView(out);

    if (endian == Endian.little) {
      out[0] = 0x49;
      out[1] = 0x49;
    } else {
      out[0] = 0x4D;
      out[1] = 0x4D;
    }

    if (!bigTiff) {
      data.setUint16(2, 42, endian);
      data.setUint32(4, ifdStart, endian);
    } else {
      data.setUint16(2, 43, endian);
      data.setUint16(4, 8, endian);
      data.setUint16(6, 0, endian);
      data.setUint64(8, ifdStart, endian);
    }

    var cursor = ifdStart;
    if (!bigTiff) {
      data.setUint16(cursor, tags.length, endian);
      cursor += 2;
    } else {
      data.setUint64(cursor, tags.length, endian);
      cursor += 8;
    }

    for (var i = 0; i < tags.length; i++) {
      final tag = tags[i];
      final entryOffset = cursor + i * entrySize;
      data.setUint16(entryOffset, tag.id, endian);
      data.setUint16(entryOffset + 2, tag.type.code, endian);
      if (!bigTiff) {
        data.setUint32(entryOffset + 4, tag.values.length, endian);
      } else {
        data.setUint64(entryOffset + 4, tag.values.length, endian);
      }

      final valueFieldOffset = entryOffset + (bigTiff ? 12 : 8);
      final bytes = valueBytesList[i];
      final overflowOffset = overflowOffsets[i];
      if (overflowOffset == null) {
        for (var b = 0; b < bytes.length; b++) {
          out[valueFieldOffset + b] = bytes[b];
        }
      } else {
        if (!bigTiff) {
          data.setUint32(valueFieldOffset, overflowOffset, endian);
        } else {
          data.setUint64(valueFieldOffset, overflowOffset, endian);
        }
        for (var b = 0; b < bytes.length; b++) {
          out[overflowOffset + b] = bytes[b];
        }
      }
    }

    final nextIfdOffsetPos = cursor + tags.length * entrySize;
    if (!bigTiff) {
      data.setUint32(nextIfdOffsetPos, 0, endian);
    } else {
      data.setUint64(nextIfdOffsetPos, 0, endian);
    }

    out.setRange(
      pixelDataOffset,
      pixelDataOffset + _pixelData.length,
      _pixelData,
    );

    return out;
  }

  Uint8List _encodeTag(_Tag tag) {
    if (tag.asciiValue != null) {
      final text = tag.asciiValue!;
      final bytes = Uint8List(text.length + 1);
      bytes.setRange(0, text.length, text.codeUnits);
      return bytes;
    }
    if (tag.doubleValues != null) {
      final values = tag.doubleValues!;
      final bytes = Uint8List(values.length * 8);
      final bd = ByteData.sublistView(bytes);
      for (var i = 0; i < values.length; i++) {
        bd.setFloat64(i * 8, values[i], endian);
      }
      return bytes;
    }
    return _encodeValues(tag.type, tag.values);
  }

  Uint8List _encodeValues(TiffTagType type, List<int> values) {
    final bytes = Uint8List(values.length * type.byteSize);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < values.length; i++) {
      final off = i * type.byteSize;
      if (type == TiffTagType.tShort) {
        bd.setUint16(off, values[i], endian);
      } else if (type == TiffTagType.tLong) {
        bd.setUint32(off, values[i], endian);
      } else {
        throw UnsupportedError(
          'Fixture builder only supports SHORT/LONG tags for now',
        );
      }
    }
    return bytes;
  }
}

class _Tag {
  final int id;
  final TiffTagType type;
  final List<int> values;
  final List<int>? stripByteCounts;
  final List<double>? doubleValues;
  final String? asciiValue;

  _Tag(
    this.id,
    this.type,
    this.values, {
    this.stripByteCounts,
    this.doubleValues,
    this.asciiValue,
  });
}
