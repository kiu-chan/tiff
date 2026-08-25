import 'dart:typed_data';

/// Where a [TiffByteReader](../core/byte_reader.dart) gets its bytes from.
///
/// Abstracting this (rather than always holding a single in-memory
/// [Uint8List]) is what lets large BigTIFF files be decoded without loading
/// the whole file into memory: a file-backed implementation only reads the
/// bytes actually requested (header, IFDs, and whichever strips/tiles are
/// decoded), see `FileByteSource` in `package:tiff/tiff_io.dart`.
abstract class TiffByteSource {
  int get length;

  Uint8List readBytes(int offset, int length);

  /// Releases any underlying resources (e.g. an open file handle).
  /// Safe to call even if there's nothing to release.
  void close() {}
}
