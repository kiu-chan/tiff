import 'dart:typed_data';

import '../../tiff_exception.dart';
import 'ccitt_decoder.dart';

/// Decodes CCITT Group 3 (Modified Huffman / T.4) and Group 4 (T.6) bilevel
/// fax data — TIFF Compression codes 2, 3, and 4.
///
/// Decode only: encoding a new CCITT-compressed strip/tile is not supported
/// (see [CompressionCodecRegistry.encode]) — virtually no modern encoder
/// writes new Group 3/4 data, so this only needs to read it.
class CcittCodec {
  const CcittCodec._();

  static Uint8List decode(
    int compressionCode,
    Uint8List input, {
    required int columns,
    required int rows,
    int t4Options = 0,
    int t6Options = 0,
  }) {
    final int k;
    var byteAlign = false;
    switch (compressionCode) {
      case 2:
        k = 0;
        break;
      case 3:
        if (t4Options & 0x2 != 0) {
          throw const TiffException(
            'CCITT T.4 uncompressed mode is not supported',
          );
        }
        k = (t4Options & 0x1) != 0 ? 1 : 0;
        byteAlign = (t4Options & 0x4) != 0;
        break;
      case 4:
        if (t6Options & 0x2 != 0) {
          throw const TiffException(
            'CCITT T.6 uncompressed mode is not supported',
          );
        }
        k = -1;
        break;
      default:
        throw TiffException(
          'Compression code $compressionCode is not a CCITT scheme',
        );
    }

    final decoder = CcittFaxDecoder(
      input,
      columns: columns,
      encoding: k,
      byteAlign: byteAlign,
    );
    return decoder.decodeRows(rows);
  }
}
