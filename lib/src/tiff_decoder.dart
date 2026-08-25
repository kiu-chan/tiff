import 'dart:typed_data';

import 'core/byte_reader.dart';
import 'core/ifd/ifd_reader.dart';
import 'core/tag_value.dart';
import 'core/tiff_header.dart';
import 'image/tiff_image.dart';
import 'tiff_document.dart';
import 'tiff_exception.dart';

/// Entry point for decoding TIFF/BigTIFF files from an in-memory buffer.
class TiffDecoder {
  const TiffDecoder._();

  static TiffDocument decode(Uint8List bytes) {
    final header = TiffHeader.parse(bytes);
    final reader = TiffByteReader(bytes, header.byteOrder.endian);

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

    return TiffDocument(images: images, isBigTiff: header.isBigTiff, byteOrder: header.byteOrder);
  }
}
