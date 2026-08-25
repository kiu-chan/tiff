import '../image/image_metadata.dart';
import '../tiff_exception.dart';

/// A rectangular sub-area of a page, in pixel coordinates, for decoding
/// less than the full image — the point being to avoid materializing an
/// entire multi-gigapixel BigTIFF page just to look at a small crop.
class TiffRegion {
  final int x;
  final int y;
  final int width;
  final int height;

  const TiffRegion({required this.x, required this.y, required this.width, required this.height});

  factory TiffRegion.fullImage(TiffImageMetadata metadata) =>
      TiffRegion(x: 0, y: 0, width: metadata.width, height: metadata.height);

  void validateWithin(TiffImageMetadata metadata) {
    if (x < 0 || y < 0 || width <= 0 || height <= 0 || x + width > metadata.width || y + height > metadata.height) {
      throw TiffException(
          'Region (x=$x, y=$y, ${width}x$height) is out of bounds for a ${metadata.width}x${metadata.height} image');
    }
  }
}
