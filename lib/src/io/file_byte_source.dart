import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../tiff_exception.dart';
import 'byte_source.dart';

/// A [TiffByteSource] backed by a file on disk, read on demand via
/// [RandomAccessFile] instead of loading the whole file into memory —
/// the point of BigTIFF, which exists for multi-gigabyte files.
///
/// Keeps a single sliding window buffer so the many small, nearby reads
/// that header/IFD parsing does don't each cost a separate disk read; only
/// a cache miss (e.g. jumping to a strip/tile far from the last read)
/// triggers real I/O.
///
/// Not available on web (`dart:io`) — kept out of the main `tiff.dart`
/// export so decoding from an in-memory buffer stays platform-agnostic.
/// Import `package:tiff/tiff_io.dart` to use this.
class FileByteSource implements TiffByteSource {
  static const int _minWindowSize = 64 * 1024;

  final RandomAccessFile _file;
  final int _length;
  Uint8List _window = Uint8List(0);
  int _windowStart = 0;

  FileByteSource._(this._file, this._length);

  static FileByteSource open(File file) {
    final raf = file.openSync();
    return FileByteSource._(raf, raf.lengthSync());
  }

  @override
  int get length => _length;

  @override
  Uint8List readBytes(int offset, int count) {
    if (offset < 0 || count < 0 || offset + count > _length) {
      throw TiffException(
          'Attempted to read past the end of the file (offset=$offset, count=$count, length=$_length)');
    }
    final windowEnd = _windowStart + _window.length;
    if (offset < _windowStart || offset + count > windowEnd) {
      _fillWindow(offset, count);
    }
    final localStart = offset - _windowStart;
    return Uint8List.sublistView(_window, localStart, localStart + count);
  }

  void _fillWindow(int offset, int count) {
    final windowSize = math.max(_minWindowSize, count);
    final end = math.min(_length, offset + windowSize);
    _file.setPositionSync(offset);
    _window = _file.readSync(end - offset);
    _windowStart = offset;
  }

  @override
  void close() => _file.closeSync();
}
