import '../core/byte_reader.dart';
import '../core/tag_value.dart';
import '../layout/strip_layout.dart';
import '../raster/raster_buffer.dart';
import '../tiff_exception.dart';
import 'image_metadata.dart';

/// One page (IFD) of a TIFF/BigTIFF file: its metadata, plus the ability to
/// decode its pixel data on demand.
class TiffImage {
  final TiffImageMetadata metadata;
  final TiffByteReader _reader;

  const TiffImage._(this.metadata, this._reader);

  factory TiffImage.fromTags(Map<int, TiffTagValue> tags, TiffByteReader reader) =>
      TiffImage._(TiffImageMetadata.fromTags(tags), reader);

  /// Decodes this page's pixel data into raw, unpacked samples.
  ///
  /// Phase 1 only supports uncompressed (Compression == 1), strip-organized
  /// data; anything else throws [TiffException] with a clear message.
  TiffRasterBuffer decode() {
    if (metadata.compression != 1) {
      throw TiffException(
          'Compression code ${metadata.compression} is not supported yet (Phase 1 supports uncompressed data only)');
    }
    return StripLayout.decodeUncompressed(reader: _reader, metadata: metadata);
  }
}
