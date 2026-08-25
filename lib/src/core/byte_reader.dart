import 'dart:typed_data';

import '../io/byte_source.dart';
import '../io/memory_byte_source.dart';

/// Reads TIFF primitive types at arbitrary offsets from a [TiffByteSource],
/// honoring the file's byte order.
///
/// Reads are offset-based (not cursor-based) because TIFF/BigTIFF constantly
/// jumps around the file (IFD chains, tag value offsets, strip/tile data).
class TiffByteReader {
  final TiffByteSource source;
  final Endian endian;

  const TiffByteReader(this.source, this.endian);

  factory TiffByteReader.fromBytes(Uint8List bytes, Endian endian) =>
      TiffByteReader(MemoryByteSource(bytes), endian);

  int get length => source.length;

  int readUint8(int offset) => _view(offset, 1).getUint8(0);

  int readInt8(int offset) => _view(offset, 1).getInt8(0);

  int readUint16(int offset) => _view(offset, 2).getUint16(0, endian);

  int readInt16(int offset) => _view(offset, 2).getInt16(0, endian);

  int readUint32(int offset) => _view(offset, 4).getUint32(0, endian);

  int readInt32(int offset) => _view(offset, 4).getInt32(0, endian);

  int readUint64(int offset) => _view(offset, 8).getUint64(0, endian);

  int readInt64(int offset) => _view(offset, 8).getInt64(0, endian);

  double readFloat32(int offset) => _view(offset, 4).getFloat32(0, endian);

  double readFloat64(int offset) => _view(offset, 8).getFloat64(0, endian);

  Uint8List readBytes(int offset, int count) => source.readBytes(offset, count);

  ByteData _view(int offset, int count) =>
      ByteData.sublistView(source.readBytes(offset, count));
}
