import 'dart:typed_data';

import 'write/tiff_image_spec.dart';
import 'write/tiff_writer.dart';

/// Entry point for writing TIFF/BigTIFF files.
class TiffEncoder {
  const TiffEncoder._();

  /// Encodes one or more pages into a single TIFF/BigTIFF file.
  ///
  /// Uses Classic TIFF (32-bit offsets) unless [bigTiff] is `true`, or the
  /// encoded pixel data is large enough that Classic's 4 GiB offset limit
  /// wouldn't fit — pass `bigTiff: false` to disable that auto-promotion
  /// and get a clear error instead of a corrupt file in that case.
  /// [onChunkEncoded], if given, is called after every strip/tile is
  /// compressed and ready to place — `pageIndex`/`pageCount` locate which
  /// page (0-based) out of [pages] it belongs to, `chunkIndex`/`chunkCount`
  /// its 1-based position within that page's own strips/tiles. Useful for a
  /// caller writing a page large enough that compression alone takes
  /// noticeable time (see `TiffDisplayOptimizer`, whose pyramid-rung
  /// progress is built on exactly this).
  static Uint8List encode(
    List<TiffImageSpec> pages, {
    bool? bigTiff,
    Endian endian = Endian.little,
    void Function(int pageIndex, int pageCount, int chunkIndex, int chunkCount)?
    onChunkEncoded,
  }) {
    return TiffWriter.write(
      pages: pages,
      forceBigTiff: bigTiff,
      endian: endian,
      onChunkEncoded: onChunkEncoded,
    );
  }
}
