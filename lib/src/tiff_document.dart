import 'core/byte_order.dart';
import 'image/tiff_image.dart';

/// A fully-parsed TIFF/BigTIFF file: its byte order/format flavor plus every
/// page found by following the IFD chain.
class TiffDocument {
  final List<TiffImage> images;
  final bool isBigTiff;
  final TiffByteOrder byteOrder;

  const TiffDocument({
    required this.images,
    required this.isBigTiff,
    required this.byteOrder,
  });
}
