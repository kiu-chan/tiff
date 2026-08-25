// Writes a small RGB TIFF, reads it back, and prints its metadata and
// pixel data — a self-contained round trip that needs no input file.
//
// Run with: dart run example/tiff_example.dart
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:tiff/tiff.dart';

void main() {
  // --- Build a tiny 4x4 RGB gradient and write it out as LZW+predictor. ---
  const width = 4;
  const height = 4;
  final samples = <int>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      samples.addAll([x * 60, y * 60, 128]); // R, G, B
    }
  }

  final spec = TiffImageSpec(
    width: width,
    height: height,
    samplesPerPixel: 3,
    bitsPerSample: 8,
    photometric: TiffPhotometric.rgb,
    samples: samples,
    compression: 5, // LZW
    predictor: 2, // horizontal differencing — pairs well with LZW/Deflate
  );

  final bytes = TiffEncoder.encode([spec]);
  final outputFile = File(
    '${Directory.systemTemp.path}/tiff_example_output.tif',
  );
  outputFile.writeAsBytesSync(bytes);
  print('Wrote ${bytes.length} bytes to ${outputFile.path}');

  // --- Read it back. ---
  final document = TiffDecoder.decode(bytes);
  final page = document.images.single;

  print(
    'Decoded: ${page.metadata.width}x${page.metadata.height}, '
    '${page.metadata.samplesPerPixel} samples/pixel, '
    'compression=${page.metadata.compression}',
  );

  final raster = page.decode(); // raw samples, no color interpretation
  print(
    'First pixel (R,G,B): '
    '${raster.sampleAt(0, 0, 0)}, ${raster.sampleAt(0, 0, 1)}, ${raster.sampleAt(0, 0, 2)}',
  );

  final Uint8List rgba = page.decodeRgba8(); // interleaved 8-bit RGBA
  print('First pixel as RGBA bytes: ${rgba.take(4).toList()}');
}
