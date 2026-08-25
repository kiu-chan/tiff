import 'core/byte_order.dart';
import 'image/tiff_image.dart';
import 'io/byte_source.dart';

/// A fully-parsed TIFF/BigTIFF file: its byte order/format flavor plus every
/// page found by following the IFD chain.
class TiffDocument {
  final List<TiffImage> images;
  final bool isBigTiff;
  final TiffByteOrder byteOrder;
  final TiffByteSource source;

  const TiffDocument({
    required this.images,
    required this.isBigTiff,
    required this.byteOrder,
    required this.source,
  });

  /// Releases the underlying byte source (e.g. closes an open file handle).
  /// Safe to call even for an in-memory document, where it's a no-op.
  void close() => source.close();
}
