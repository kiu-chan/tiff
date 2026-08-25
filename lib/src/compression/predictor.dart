import 'dart:typed_data';

import '../tiff_exception.dart';

/// Undoes Predictor (tag 317) horizontal differencing on one already
/// decompressed row, in place, before samples are unpacked.
///
/// Only Predictor 2 (horizontal differencing) is implemented; Predictor 3
/// (floating point) is a distinct, more involved byte-shuffling scheme and
/// is not supported yet.
class Predictor {
  const Predictor._();

  static void undoHorizontalDifferencing({
    required Uint8List rowBytes,
    required int bitsPerSample,
    required int samplesPerPixel,
    required Endian endian,
  }) {
    if (bitsPerSample == 8) {
      for (var i = samplesPerPixel; i < rowBytes.length; i++) {
        rowBytes[i] = (rowBytes[i] + rowBytes[i - samplesPerPixel]) & 0xFF;
      }
      return;
    }

    if (bitsPerSample == 16) {
      final data = ByteData.sublistView(rowBytes);
      final sampleCount = rowBytes.length ~/ 2;
      for (var i = samplesPerPixel; i < sampleCount; i++) {
        final prev = data.getUint16((i - samplesPerPixel) * 2, endian);
        final cur = data.getUint16(i * 2, endian);
        data.setUint16(i * 2, (cur + prev) & 0xFFFF, endian);
      }
      return;
    }

    throw TiffException(
        'Horizontal predictor is only supported for 8/16-bit samples (got $bitsPerSample-bit)');
  }
}
