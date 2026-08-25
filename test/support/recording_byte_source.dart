import 'dart:typed_data';

import 'package:tiff/tiff.dart';

/// Wraps a [TiffByteSource] and records every offset it's asked to read,
/// so tests can assert that region/lazy decoding actually skips the reads
/// it claims to skip (not just that the output happens to be correct).
class RecordingByteSource implements TiffByteSource {
  final TiffByteSource inner;
  final List<int> readOffsets = [];

  RecordingByteSource(this.inner);

  @override
  int get length => inner.length;

  @override
  Uint8List readBytes(int offset, int length) {
    readOffsets.add(offset);
    return inner.readBytes(offset, length);
  }

  @override
  void close() => inner.close();
}
