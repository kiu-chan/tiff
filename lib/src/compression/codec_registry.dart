import 'dart:typed_data';

import '../tiff_exception.dart';
import 'ccitt/ccitt_codec.dart';
import 'deflate_codec.dart';
import 'lzw_codec.dart';
import 'packbits_codec.dart';

/// Dispatches a strip/tile's raw bytes to the codec matching its
/// Compression tag value.
class CompressionCodecRegistry {
  const CompressionCodecRegistry._();

  /// [columns]/[rows] and the T4/T6 options are only used by the CCITT
  /// codecs (2/3/4), which — unlike the other schemes — decode a bitmap of
  /// known dimensions rather than an opaque byte stream.
  static Uint8List decode(
    int compressionCode,
    Uint8List input, {
    int? columns,
    int? rows,
    int t4Options = 0,
    int t6Options = 0,
  }) {
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
      case 2:
      case 3:
      case 4:
        if (columns == null || rows == null) {
          throw const TiffException(
            'CCITT compression requires a known chunk width/row count',
          );
        }
        return CcittCodec.decode(
          compressionCode,
          input,
          columns: columns,
          rows: rows,
          t4Options: t4Options,
          t6Options: t6Options,
        );
      default:
        throw TiffException(
          'Compression code $compressionCode is not supported yet',
        );
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
      case 2:
      case 3:
      case 4:
        throw TiffException(
          'CCITT Group 3/4 encoding (compression $compressionCode) is not supported — decode only',
        );
      default:
        throw TiffException(
          'Compression code $compressionCode is not supported yet for encoding',
        );
    }
  }
}
