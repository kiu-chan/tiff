import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Deflate/ZIP compression (Compression 8 "Adobe Deflate" and the older,
/// equivalent code 32946). Wraps `package:archive`'s zlib implementation
/// rather than shipping a hand-rolled inflate.
class DeflateCodec {
  const DeflateCodec._();

  static Uint8List decode(Uint8List input) {
    final decoded = const ZLibDecoder().decodeBytes(input);
    return Uint8List.fromList(decoded);
  }

  static Uint8List encode(Uint8List input) {
    final encoded = const ZLibEncoder().encode(input);
    return Uint8List.fromList(encoded);
  }
}
