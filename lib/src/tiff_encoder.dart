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
  static Uint8List encode(
    List<TiffImageSpec> pages, {
    bool? bigTiff,
    Endian endian = Endian.little,
  }) {
    return TiffWriter.write(
      pages: pages,
      forceBigTiff: bigTiff,
      endian: endian,
    );
  }
}
