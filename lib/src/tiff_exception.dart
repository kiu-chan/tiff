/// Thrown when a TIFF/BigTIFF file is malformed or uses a feature that is
/// not supported by the current phase of the decoder/encoder.
class TiffException implements Exception {
  final String message;

  const TiffException(this.message);

  @override
  String toString() => 'TiffException: $message';
}
