import 'dart:typed_data';

/// Thin, allocation-light wrapper around a [Uint8List] that reads TIFF
/// primitive types at arbitrary offsets, honoring the file's byte order.
///
/// Reads are offset-based (not cursor-based) because TIFF/BigTIFF constantly
/// jumps around the file (IFD chains, tag value offsets, strip/tile data).
class TiffByteReader {
  final Uint8List bytes;
  final Endian endian;
  final ByteData _data;

  TiffByteReader(this.bytes, this.endian) : _data = ByteData.sublistView(bytes);

  int get length => bytes.length;

  int readUint8(int offset) => _data.getUint8(offset);

  int readInt8(int offset) => _data.getInt8(offset);

  int readUint16(int offset) => _data.getUint16(offset, endian);

  int readInt16(int offset) => _data.getInt16(offset, endian);

  int readUint32(int offset) => _data.getUint32(offset, endian);

  int readInt32(int offset) => _data.getInt32(offset, endian);

  int readUint64(int offset) => _data.getUint64(offset, endian);

  int readInt64(int offset) => _data.getInt64(offset, endian);

  double readFloat32(int offset) => _data.getFloat32(offset, endian);

  double readFloat64(int offset) => _data.getFloat64(offset, endian);

  Uint8List readBytes(int offset, int count) => Uint8List.sublistView(bytes, offset, offset + count);
}
