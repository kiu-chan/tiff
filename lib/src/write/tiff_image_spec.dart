import '../image/photometric.dart';
import '../tiff_exception.dart';

/// Everything needed to write one TIFF/BigTIFF page.
///
/// Mirrors what [TiffImage]/[TiffRasterBuffer] expose on the decode side:
/// a single uniform BitsPerSample across channels, chunky (interleaved)
/// sample order, and — if [tileWidth]/[tileLength] are both set — tiled
/// rather than strip layout.
class TiffImageSpec {
  final int width;
  final int height;
  final int samplesPerPixel;
  final int bitsPerSample;
  final TiffPhotometric photometric;

  /// Raw samples, row-major, interleaved: length must be
  /// `width * height * samplesPerPixel`.
  final List<int> samples;

  /// Compression tag value (1=None, 5=LZW, 8/32946=Deflate, 32773=PackBits).
  final int compression;

  /// Predictor tag value: 1=None, 2=horizontal differencing (8/16-bit only).
  final int predictor;

  /// Required when [photometric] is [TiffPhotometric.palette]: three
  /// `2^bitsPerSample`-entry lookup tables (R, then G, then B), 16-bit each.
  final List<int>? colorMap;

  /// Strip layout when null; ignored if [tileWidth]/[tileLength] are set.
  final int? rowsPerStrip;

  final int? tileWidth;
  final int? tileLength;

  TiffImageSpec({
    required this.width,
    required this.height,
    required this.samplesPerPixel,
    required this.bitsPerSample,
    required this.photometric,
    required this.samples,
    this.compression = 1,
    this.predictor = 1,
    this.colorMap,
    this.rowsPerStrip,
    this.tileWidth,
    this.tileLength,
  }) {
    if (samples.length != width * height * samplesPerPixel) {
      throw TiffException(
          'samples has ${samples.length} entries, expected ${width * height * samplesPerPixel} '
          '(width * height * samplesPerPixel)');
    }
    if (bitsPerSample < 1 || bitsPerSample > 32) {
      throw TiffException('bitsPerSample must be in [1, 32], got $bitsPerSample');
    }
    if ((tileWidth == null) != (tileLength == null)) {
      throw const TiffException('tileWidth and tileLength must be set together');
    }
    if (isTiled && rowsPerStrip != null) {
      throw const TiffException('rowsPerStrip is not used for tiled images');
    }
  }

  bool get isTiled => tileWidth != null;
}
