import 'dart:typed_data';

import 'core/byte_reader.dart';
import 'core/ifd/ifd_reader.dart';
import 'core/tag_value.dart';
import 'core/tiff_header.dart';
import 'image/tiff_image.dart';
import 'io/byte_source.dart';
import 'io/memory_byte_source.dart';
import 'tiff_document.dart';
import 'tiff_exception.dart';

/// Entry point for decoding TIFF/BigTIFF files.
class TiffDecoder {
  const TiffDecoder._();

  /// Decodes from an in-memory buffer.
  static TiffDocument decode(Uint8List bytes) => decodeSource(MemoryByteSource(bytes));

  /// Decodes from any [TiffByteSource] — use this with a file-backed source
  /// (see `package:tiff/tiff_io.dart`) to avoid loading a large BigTIFF
  /// file fully into memory. Only the header, IFDs, and whichever
  /// strips/tiles are later decoded actually get read from the source.
  static TiffDocument decodeSource(TiffByteSource source) {
    final header = TiffHeader.parse(source);
    final reader = TiffByteReader(source, header.byteOrder.endian);

    final images = <TiffImage>[];
    int? nextIfdOffset = header.firstIfdOffset;

    while (nextIfdOffset != null && nextIfdOffset != 0) {
      final result = TiffIfdReader.read(reader, nextIfdOffset, isBigTiff: header.isBigTiff);

      final tags = <int, TiffTagValue>{};
      for (final entry in result.entries) {
        tags[entry.tagId] = TiffIfdReader.resolveValue(reader, entry, isBigTiff: header.isBigTiff);
      }

      images.add(TiffImage.fromTags(tags, reader));
      nextIfdOffset = result.nextIfdOffset == 0 ? null : result.nextIfdOffset;
    }

    if (images.isEmpty) {
      throw const TiffException('TIFF file contains no image directories');
    }

    return TiffDocument(images: images, isBigTiff: header.isBigTiff, byteOrder: header.byteOrder, source: source);
  }
}
