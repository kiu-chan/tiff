/// Optional file-based decoding entry point.
///
/// Uses `dart:io`, so it's not available on web — kept separate from
/// `package:tiff/tiff.dart` so the core library stays platform-agnostic.
/// Import this in addition when you want to decode straight from a [File]
/// without loading it fully into memory (the point of BigTIFF).
library;

import 'dart:io';

import 'src/io/file_byte_source.dart';
import 'tiff.dart';

export 'src/io/file_byte_source.dart' show FileByteSource;
export 'src/io/system_memory_info.dart' show SystemMemoryInfo;
export 'src/io/tiff_auto_decode_budget.dart' show TiffAutoDecodeBudget;
export 'src/io/tiff_parallel_decoder.dart' show TiffBand, TiffParallelDecoder;

/// Opens [file] and decodes it lazily: only the header, IFDs, and whichever
/// strips/tiles are later decoded (via [TiffImage.decode] /
/// [TiffImage.decodeRegion]) are actually read from disk.
///
/// Call [TiffDocument.close] when done to release the file handle.
TiffDocument decodeTiffFile(File file) =>
    TiffDecoder.decodeSource(FileByteSource.open(file));
