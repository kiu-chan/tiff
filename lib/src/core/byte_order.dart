import 'dart:typed_data';

/// Byte order marker found at the very start of a TIFF/BigTIFF file.
enum TiffByteOrder {
  little,
  big;

  Endian get endian =>
      this == TiffByteOrder.little ? Endian.little : Endian.big;
}
