import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

void main() {
  group('ImageAdjustments.apply', () {
    test('default parameters are a no-op (identity, same instance)', () {
      final rgba = Uint8List.fromList([10, 20, 30, 255, 200, 100, 50, 128]);
      final result = ImageAdjustments.apply(rgba);
      expect(identical(result, rgba), isTrue);
    });

    test('brightness shifts RGB channels but leaves alpha untouched', () {
      final rgba = Uint8List.fromList([10, 20, 30, 40]);
      final result = ImageAdjustments.apply(rgba, brightness: 50);
      expect(result, [60, 70, 80, 40]);
    });

    test('brightness clamps at 0 and 255', () {
      final rgba = Uint8List.fromList([10, 250, 0, 255]);
      final darker = ImageAdjustments.apply(rgba, brightness: -50);
      expect(darker, [0, 200, 0, 255]);
      final brighter = ImageAdjustments.apply(rgba, brightness: 50);
      expect(brighter, [60, 255, 50, 255]);
    });

    test('contrast expands values away from mid-gray (127.5)', () {
      final rgba = Uint8List.fromList([
        227,
        27,
        127,
        255,
      ]); // +100/-100/~mid from 127.5
      final result = ImageAdjustments.apply(rgba, contrast: 2.0);
      // (227-127.5)*2+127.5=327.5->255 clamp; (27-127.5)*2+127.5=-72.5->0 clamp;
      // (127-127.5)*2+127.5=126.5->127 (rounds to 127).
      expect(result, [255, 0, 127, 255]);
    });

    test('contrast of 0 collapses every channel to mid-gray', () {
      final rgba = Uint8List.fromList([0, 128, 255, 255]);
      final result = ImageAdjustments.apply(rgba, contrast: 0);
      expect(result[0], inInclusiveRange(127, 128));
      expect(result[1], inInclusiveRange(127, 128));
      expect(result[2], inInclusiveRange(127, 128));
      expect(result[3], 255); // alpha untouched
    });

    test('gamma > 1 brightens midtones', () {
      final rgba = Uint8List.fromList([128, 128, 128, 255]);
      final result = ImageAdjustments.apply(rgba, gamma: 2.2);
      expect(result[0], greaterThan(128));
      expect(result[1], greaterThan(128));
      expect(result[2], greaterThan(128));
    });

    test('gamma < 1 darkens midtones', () {
      final rgba = Uint8List.fromList([128, 128, 128, 255]);
      final result = ImageAdjustments.apply(rgba, gamma: 0.5);
      expect(result[0], lessThan(128));
    });

    test('gamma leaves pure black and pure white unchanged', () {
      final rgba = Uint8List.fromList([0, 255, 0, 255]);
      final result = ImageAdjustments.apply(rgba, gamma: 3.0);
      expect(result, [0, 255, 0, 255]);
    });

    test(
      'adjustments compose across a whole buffer, alpha always preserved',
      () {
        final rgba = Uint8List.fromList([
          0, 128, 255, 10, //
          50, 60, 70, 200,
        ]);
        final result = ImageAdjustments.apply(
          rgba,
          brightness: 10,
          contrast: 1.2,
          gamma: 1.1,
        );
        expect(result.length, rgba.length);
        expect(result[3], 10);
        expect(result[7], 200);
      },
    );

    test('rejects a buffer whose length is not a multiple of 4', () {
      expect(
        () => ImageAdjustments.apply(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<TiffException>()),
      );
    });

    test('rejects a non-positive gamma', () {
      expect(
        () =>
            ImageAdjustments.apply(Uint8List.fromList([1, 2, 3, 4]), gamma: 0),
        throwsA(isA<TiffException>()),
      );
      expect(
        () =>
            ImageAdjustments.apply(Uint8List.fromList([1, 2, 3, 4]), gamma: -1),
        throwsA(isA<TiffException>()),
      );
    });
  });
}
