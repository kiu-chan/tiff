import 'dart:typed_data';

import '../tiff_exception.dart';
import 'deflate_codec.dart';
import 'lzw_codec.dart';
import 'packbits_codec.dart';

/// Dispatches a strip/tile's raw bytes to the codec matching its
/// Compression tag value.
class CompressionCodecRegistry {
  const CompressionCodecRegistry._();

  static Uint8List decode(int compressionCode, Uint8List input) {
    switch (compressionCode) {
      case 1:
        return input;
      case 5:
        return LzwCodec.decode(input);
      case 32773:
        return PackBitsCodec.decode(input);
      case 8:
      case 32946:
        return DeflateCodec.decode(input);
      default:
        throw TiffException('Compression code $compressionCode is not supported yet');
    }
  }

  static Uint8List encode(int compressionCode, Uint8List input) {
    switch (compressionCode) {
      case 1:
        return input;
      case 5:
        return LzwCodec.encode(input);
      case 32773:
        return PackBitsCodec.encode(input);
      case 8:
      case 32946:
        return DeflateCodec.encode(input);
      default:
        throw TiffException('Compression code $compressionCode is not supported yet for encoding');
    }
  }
}
