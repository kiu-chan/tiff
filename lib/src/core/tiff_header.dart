import '../io/byte_source.dart';
import '../tiff_exception.dart';
import 'byte_order.dart';
import 'byte_reader.dart';

/// Parsed result of the fixed-size header every TIFF/BigTIFF file starts
/// with: byte order marker, magic number, and the offset of the first IFD.
class TiffHeader {
  final TiffByteOrder byteOrder;
  final bool isBigTiff;
  final int firstIfdOffset;

  const TiffHeader({
    required this.byteOrder,
    required this.isBigTiff,
    required this.firstIfdOffset,
  });

  static const int _classicMagic = 42;
  static const int _bigTiffMagic = 43;

  /// Parses the header from the start of [source].
  ///
  /// Recognizes Classic TIFF (32-bit offsets, magic 42) and BigTIFF
  /// (64-bit offsets, magic 43). Throws [TiffException] for anything else.
  static TiffHeader parse(TiffByteSource source) {
    if (source.length < 8) {
      throw const TiffException('File is too small to contain a valid TIFF header');
    }

    final marker = source.readBytes(0, 2);
    final TiffByteOrder byteOrder;
    if (marker[0] == 0x49 && marker[1] == 0x49) {
      byteOrder = TiffByteOrder.little;
    } else if (marker[0] == 0x4D && marker[1] == 0x4D) {
      byteOrder = TiffByteOrder.big;
    } else {
      throw const TiffException('Not a TIFF file: invalid byte order marker');
    }

    final reader = TiffByteReader(source, byteOrder.endian);
    final magic = reader.readUint16(2);

    if (magic == _classicMagic) {
      final firstIfdOffset = reader.readUint32(4);
      return TiffHeader(byteOrder: byteOrder, isBigTiff: false, firstIfdOffset: firstIfdOffset);
    }

    if (magic == _bigTiffMagic) {
      if (source.length < 16) {
        throw const TiffException('File is too small to contain a valid BigTIFF header');
      }
      final offsetByteSize = reader.readUint16(4);
      if (offsetByteSize != 8) {
        throw TiffException('Unsupported BigTIFF offset byte size: $offsetByteSize');
      }
      final constant = reader.readUint16(6);
      if (constant != 0) {
        throw TiffException('Invalid BigTIFF header constant: $constant (expected 0)');
      }
      final firstIfdOffset = reader.readUint64(8);
      return TiffHeader(byteOrder: byteOrder, isBigTiff: true, firstIfdOffset: firstIfdOffset);
    }

    throw TiffException('Unsupported TIFF magic number: $magic');
  }
}
