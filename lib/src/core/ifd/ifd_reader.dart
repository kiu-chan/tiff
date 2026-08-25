import 'dart:typed_data';

import '../../tiff_exception.dart';
import '../byte_reader.dart';
import '../tag_type.dart';
import '../tag_value.dart';
import 'ifd_entry.dart';

/// Result of reading one IFD: its entries plus the offset of the next IFD
/// in the chain (0 means "no more IFDs" — i.e. last page).
class IfdReadResult {
  final List<TiffIfdEntry> entries;
  final int nextIfdOffset;

  const IfdReadResult(this.entries, this.nextIfdOffset);
}

/// Reads IFDs (Classic: 2-byte count + 12-byte entries; BigTIFF: 8-byte
/// count + 20-byte entries) and resolves entry value/offset fields into
/// typed [TiffTagValue]s.
class TiffIfdReader {
  const TiffIfdReader._();

  static IfdReadResult read(
    TiffByteReader reader,
    int offset, {
    required bool isBigTiff,
  }) {
    final entrySize = isBigTiff ? 20 : 12;
    final offsetFieldSize = isBigTiff ? 8 : 4;

    int cursor = offset;
    final int entryCount;
    if (isBigTiff) {
      entryCount = reader.readUint64(cursor);
      cursor += 8;
    } else {
      entryCount = reader.readUint16(cursor);
      cursor += 2;
    }

    final entries = <TiffIfdEntry>[];
    for (var i = 0; i < entryCount; i++) {
      final entryOffset = cursor + i * entrySize;
      final tagId = reader.readUint16(entryOffset);
      final rawTypeCode = reader.readUint16(entryOffset + 2);
      final type = TiffTagType.fromCode(rawTypeCode);
      final count = isBigTiff
          ? reader.readUint64(entryOffset + 4)
          : reader.readUint32(entryOffset + 4);
      final valueFieldOffset = entryOffset + (isBigTiff ? 12 : 8);
      final valueField = reader.readBytes(valueFieldOffset, offsetFieldSize);
      entries.add(
        TiffIfdEntry(
          tagId: tagId,
          type: type,
          rawTypeCode: rawTypeCode,
          count: count,
          valueField: valueField,
        ),
      );
    }

    final nextOffsetPosition = cursor + entryCount * entrySize;
    final nextIfdOffset = isBigTiff
        ? reader.readUint64(nextOffsetPosition)
        : reader.readUint32(nextOffsetPosition);

    return IfdReadResult(entries, nextIfdOffset);
  }

  /// Resolves an entry's actual value(s), following the offset into the
  /// file body when the value doesn't fit inline in the value/offset field.
  static TiffTagValue resolveValue(
    TiffByteReader reader,
    TiffIfdEntry entry, {
    required bool isBigTiff,
  }) {
    final type = entry.type;
    if (type == null) {
      throw TiffException(
        'Unsupported tag type code ${entry.rawTypeCode} for tag ${entry.tagId}',
      );
    }

    final totalBytes = type.byteSize * entry.count;
    final inlineLimit = isBigTiff ? 8 : 4;

    final Uint8List dataBytes;
    if (totalBytes <= inlineLimit) {
      dataBytes = entry.valueField;
    } else {
      final fieldData = ByteData.sublistView(entry.valueField);
      final valueOffset = isBigTiff
          ? fieldData.getUint64(0, reader.endian)
          : fieldData.getUint32(0, reader.endian);
      dataBytes = reader.readBytes(valueOffset, totalBytes);
    }

    final valueReader = TiffByteReader.fromBytes(dataBytes, reader.endian);

    if (type == TiffTagType.tAscii) {
      final nullIndex = dataBytes.indexOf(0);
      final stringBytes = nullIndex >= 0
          ? dataBytes.sublist(0, nullIndex)
          : dataBytes;
      return TiffTagValue.ascii(String.fromCharCodes(stringBytes));
    }

    if (type == TiffTagType.tRational || type == TiffTagType.tSrational) {
      final signed = type == TiffTagType.tSrational;
      final rationals = <TiffRational>[];
      for (var i = 0; i < entry.count; i++) {
        final off = i * 8;
        final n = signed
            ? valueReader.readInt32(off)
            : valueReader.readUint32(off);
        final d = signed
            ? valueReader.readInt32(off + 4)
            : valueReader.readUint32(off + 4);
        rationals.add(TiffRational(n, d));
      }
      return TiffTagValue.rationals(type, rationals);
    }

    if (type == TiffTagType.tFloat) {
      return TiffTagValue.floats(type, [
        for (var i = 0; i < entry.count; i++) valueReader.readFloat32(i * 4),
      ]);
    }

    if (type == TiffTagType.tDouble) {
      return TiffTagValue.floats(type, [
        for (var i = 0; i < entry.count; i++) valueReader.readFloat64(i * 8),
      ]);
    }

    // Remaining types are all integer families of a fixed byte size:
    // BYTE/SBYTE/UNDEFINED (1), SHORT/SSHORT (2), LONG/SLONG/IFD (4),
    // LONG8/SLONG8/IFD8 (8).
    final ints = <int>[];
    for (var i = 0; i < entry.count; i++) {
      final off = i * type.byteSize;
      switch (type.byteSize) {
        case 1:
          ints.add(
            type == TiffTagType.tSbyte
                ? valueReader.readInt8(off)
                : valueReader.readUint8(off),
          );
          break;
        case 2:
          ints.add(
            type == TiffTagType.tSshort
                ? valueReader.readInt16(off)
                : valueReader.readUint16(off),
          );
          break;
        case 4:
          ints.add(
            type == TiffTagType.tSlong
                ? valueReader.readInt32(off)
                : valueReader.readUint32(off),
          );
          break;
        case 8:
          ints.add(
            type == TiffTagType.tSlong8
                ? valueReader.readInt64(off)
                : valueReader.readUint64(off),
          );
          break;
      }
    }
    return TiffTagValue.ints(type, ints);
  }
}
