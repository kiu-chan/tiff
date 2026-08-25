import 'dart:typed_data';

import 'byte_source.dart';

/// A [TiffByteSource] backed by an already-in-memory buffer.
class MemoryByteSource implements TiffByteSource {
  final Uint8List bytes;

  const MemoryByteSource(this.bytes);

  @override
  int get length => bytes.length;

  @override
  Uint8List readBytes(int offset, int length) =>
      Uint8List.sublistView(bytes, offset, offset + length);

  @override
  void close() {}
}
