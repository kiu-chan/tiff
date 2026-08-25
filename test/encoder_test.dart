import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/src/write/bigtiff_promotion.dart';

void main() {
  group('TiffEncoder round-trips', () {
    test('uncompressed grayscale strips', () {
      final samples = List.generate(16, (i) => i * 3);
      final spec = TiffImageSpec(
        width: 4,
        height: 4,
        samplesPerPixel: 1,
        bitsPerSample: 8,
        photometric: TiffPhotometric.blackIsZero,
        samples: samples,
        rowsPerStrip: 2,
      );

      final bytes = TiffEncoder.encode([spec]);
      final doc = TiffDecoder.decode(bytes);
      expect(doc.isBigTiff, isFalse);

      final image = doc.images.single;
      expect(image.metadata.width, 4);
      expect(image.metadata.height, 4);
      expect(image.metadata.rowsPerStrip, 2);
      expect(image.decode().samples, samples);
    });

    test('LZW-compressed RGB strips', () {
      final samples = List.generate(3 * 4 * 4, (i) => (i * 7) % 256);
      final spec = TiffImageSpec(
        width: 4,
        height: 4,
        samplesPerPixel: 3,
        bitsPerSample: 8,
        photometric: TiffPhotometric.rgb,
        samples: samples,
        compression: 5,
      );

      final bytes = TiffEncoder.encode([spec]);
      final image = TiffDecoder.decode(bytes).images.single;
      expect(image.metadata.compression, 5);
      expect(image.decode().samples, samples);
    });

    test('Deflate-compressed strips with a horizontal predictor', () {
      final samples = List.generate(2 * 6 * 6, (i) => (i * 13) % 256);
      final spec = TiffImageSpec(
        width: 6,
        height: 6,
        samplesPerPixel: 2,
        bitsPerSample: 8,
        photometric: TiffPhotometric.blackIsZero,
        samples: samples,
        compression: 8,
        predictor: 2,
      );

      final bytes = TiffEncoder.encode([spec]);
      final image = TiffDecoder.decode(bytes).images.single;
      expect(image.metadata.predictor, 2);
      expect(image.decode().samples, samples);
    });

    test('PackBits-compressed tiled image, including a cropped edge tile', () {
      // 5x5 doesn't divide evenly into 2x2 tiles.
      final samples = List.generate(25, (i) => i);
      final spec = TiffImageSpec(
        width: 5,
        height: 5,
        samplesPerPixel: 1,
        bitsPerSample: 8,
        photometric: TiffPhotometric.blackIsZero,
        samples: samples,
        compression: 32773,
        tileWidth: 2,
        tileLength: 2,
      );

      final bytes = TiffEncoder.encode([spec]);
      final image = TiffDecoder.decode(bytes).images.single;
      expect(image.metadata.isTiled, isTrue);
      expect(image.decode().samples, samples);
    });

    test('palette image with a ColorMap', () {
      final samples = [0, 1, 1, 0];
      final colorMap = [
        0, 65535, // red table
        65535, 0, // green table
        0, 0, // blue table
      ];
      final spec = TiffImageSpec(
        width: 2,
        height: 2,
        samplesPerPixel: 1,
        bitsPerSample: 1,
        photometric: TiffPhotometric.palette,
        samples: samples,
        colorMap: colorMap,
      );

      final bytes = TiffEncoder.encode([spec]);
      final image = TiffDecoder.decode(bytes).images.single;
      expect(image.metadata.colorMap, colorMap);
      expect(image.decode().samples, samples);
      final rgba = image.decodeRgba8();
      // index0 -> (red=0, green=65535, blue=0) = green; index1 -> (255,0,0) = red.
      expect(rgba, [
        0,
        255,
        0,
        255,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        255,
      ]);
    });

    test('multi-page files chain IFDs correctly', () {
      final page1Samples = List.generate(4, (i) => i);
      final page2Samples = List.generate(9, (i) => i + 100);
      final spec1 = TiffImageSpec(
        width: 2,
        height: 2,
        samplesPerPixel: 1,
        bitsPerSample: 8,
        photometric: TiffPhotometric.blackIsZero,
        samples: page1Samples,
      );
      final spec2 = TiffImageSpec(
        width: 3,
        height: 3,
        samplesPerPixel: 1,
        bitsPerSample: 8,
        photometric: TiffPhotometric.blackIsZero,
        samples: page2Samples,
      );

      final bytes = TiffEncoder.encode([spec1, spec2]);
      final doc = TiffDecoder.decode(bytes);
      expect(doc.images, hasLength(2));
      expect(doc.images[0].decode().samples, page1Samples);
      expect(doc.images[1].decode().samples, page2Samples);
    });

    test('forced BigTIFF round-trips identically to Classic', () {
      final samples = List.generate(16, (i) => i * 5);
      final spec = TiffImageSpec(
        width: 4,
        height: 4,
        samplesPerPixel: 1,
        bitsPerSample: 8,
        photometric: TiffPhotometric.blackIsZero,
        samples: samples,
      );

      final bytes = TiffEncoder.encode([spec], bigTiff: true);
      final doc = TiffDecoder.decode(bytes);
      expect(doc.isBigTiff, isTrue);
      expect(doc.images.single.decode().samples, samples);
    });

    test('big-endian output decodes back correctly', () {
      final samples = List.generate(16, (i) => 255 - i);
      final spec = TiffImageSpec(
        width: 4,
        height: 4,
        samplesPerPixel: 1,
        bitsPerSample: 16,
        photometric: TiffPhotometric.blackIsZero,
        samples: samples,
      );

      final bytes = TiffEncoder.encode([spec], endian: Endian.big);
      final doc = TiffDecoder.decode(bytes);
      expect(doc.byteOrder, TiffByteOrder.big);
      expect(doc.images.single.decode().samples, samples);
    });

    test('24-bit samples round-trip (little-endian)', () {
      // A byte-aligned but non-8/16/32 depth: regression test for a bug
      // where PixelPacker/PixelUnpacker's fast path accepted byteWidth==3
      // but its switch had no case for it, silently producing all-zero data.
      final samples = List.generate(16, (i) => 1 + i * 65793); // spread bits
      final spec = TiffImageSpec(
        width: 4,
        height: 4,
        samplesPerPixel: 1,
        bitsPerSample: 24,
        photometric: TiffPhotometric.blackIsZero,
        samples: samples,
      );

      final bytes = TiffEncoder.encode([spec], endian: Endian.little);
      final image = TiffDecoder.decode(bytes).images.single;
      expect(image.decode().samples, samples);
    });

    test('24-bit samples round-trip (big-endian)', () {
      final samples = List.generate(16, (i) => 1 + i * 65793);
      final spec = TiffImageSpec(
        width: 4,
        height: 4,
        samplesPerPixel: 1,
        bitsPerSample: 24,
        photometric: TiffPhotometric.blackIsZero,
        samples: samples,
      );

      final bytes = TiffEncoder.encode([spec], endian: Endian.big);
      final image = TiffDecoder.decode(bytes).images.single;
      expect(image.decode().samples, samples);
    });
  });

  group('TiffImageSpec validation', () {
    test('rejects a samples list of the wrong length', () {
      expect(
        () => TiffImageSpec(
          width: 2,
          height: 2,
          samplesPerPixel: 1,
          bitsPerSample: 8,
          photometric: TiffPhotometric.blackIsZero,
          samples: [1, 2, 3],
        ),
        throwsA(isA<TiffException>()),
      );
    });

    test('rejects tileWidth without tileLength', () {
      expect(
        () => TiffImageSpec(
          width: 2,
          height: 2,
          samplesPerPixel: 1,
          bitsPerSample: 8,
          photometric: TiffPhotometric.blackIsZero,
          samples: [1, 2, 3, 4],
          tileWidth: 2,
        ),
        throwsA(isA<TiffException>()),
      );
    });
  });

  group('BigTiffPromotion (unit)', () {
    test('stays Classic below the safety-margined 4 GiB threshold', () {
      expect(
        BigTiffPromotion.shouldUseBigTiff(totalPixelDataBytes: 1024),
        isFalse,
      );
    });

    test('auto-promotes once total pixel data approaches 4 GiB', () {
      expect(
        BigTiffPromotion.shouldUseBigTiff(
          totalPixelDataBytes: BigTiffPromotion.classicOffsetLimit,
        ),
        isTrue,
      );
    });

    test(
      'an explicit forceBigTiff overrides the size heuristic either way',
      () {
        expect(
          BigTiffPromotion.shouldUseBigTiff(
            totalPixelDataBytes: 1024,
            forceBigTiff: true,
          ),
          isTrue,
        );
        expect(
          BigTiffPromotion.shouldUseBigTiff(
            totalPixelDataBytes: BigTiffPromotion.classicOffsetLimit,
            forceBigTiff: false,
          ),
          isFalse,
        );
      },
    );
  });
}
