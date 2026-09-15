import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_viewer.dart';

typedef _Rgb = (int, int, int);

const _red = (255, 0, 0);
const _blue = (0, 0, 255);
const _viewport = Size(800, 400);
const _boundaryKey = Key('boundary');

/// A classic little-endian TIFF of one tiled, JPEG-compressed (7) page —
/// `TiffEncoder` doesn't write JPEG. Each tile is a solid [color]; tiles in
/// [sparse] are left out (byte count 0).
Uint8List _jpegTiff({
  required int width,
  required int height,
  required int tile,
  required _Rgb Function(int tileX, int tileY) color,
  int photometric = 6,
  Set<(int, int)> sparse = const {},
}) {
  final across = (width + tile - 1) ~/ tile;
  final down = (height + tile - 1) ~/ tile;
  final tiles = <Uint8List>[
    for (var ty = 0; ty < down; ty++)
      for (var tx = 0; tx < across; tx++)
        if (sparse.contains((tx, ty)))
          Uint8List(0)
        else
          img.encodeJpg(
            img.Image(width: tile, height: tile)..clear(
              img.ColorRgb8(
                color(tx, ty).$1,
                color(tx, ty).$2,
                color(tx, ty).$3,
              ),
            ),
            quality: 95,
          ),
  ];
  final count = tiles.length;
  const bitsOffset = 8;
  const dataOffset = bitsOffset + 6;
  final dataLength = tiles.fold<int>(0, (sum, t) => sum + t.length);
  final offsetsOffset = dataOffset + dataLength;
  final countsOffset = offsetsOffset + 4 * count;
  final ifdOffset = countsOffset + 4 * count;
  const entries = 11;
  final bytes = ByteData(ifdOffset + 2 + entries * 12 + 4);
  final out = bytes.buffer.asUint8List();

  out.setAll(0, [0x49, 0x49]);
  bytes.setUint16(2, 42, Endian.little);
  bytes.setUint32(4, ifdOffset, Endian.little);
  for (var i = 0; i < 3; i++) {
    bytes.setUint16(bitsOffset + 2 * i, 8, Endian.little);
  }
  var position = dataOffset;
  for (var i = 0; i < count; i++) {
    bytes.setUint32(
      offsetsOffset + 4 * i,
      tiles[i].isEmpty ? 0 : position,
      Endian.little,
    );
    bytes.setUint32(countsOffset + 4 * i, tiles[i].length, Endian.little);
    out.setAll(position, tiles[i]);
    position += tiles[i].length;
  }

  var entry = ifdOffset + 2;
  bytes.setUint16(ifdOffset, entries, Endian.little);
  void add(int tag, int type, int valueCount, int value) {
    bytes.setUint16(entry, tag, Endian.little);
    bytes.setUint16(entry + 2, type, Endian.little);
    bytes.setUint32(entry + 4, valueCount, Endian.little);
    if (type == 3 && valueCount == 1) {
      bytes.setUint16(entry + 8, value, Endian.little);
    } else {
      bytes.setUint32(entry + 8, value, Endian.little);
    }
    entry += 12;
  }

  const short = 3;
  const long = 4;
  add(256, long, 1, width);
  add(257, long, 1, height);
  add(258, short, 3, bitsOffset);
  add(259, short, 1, 7);
  add(262, short, 1, photometric);
  add(277, short, 1, 3);
  add(284, short, 1, 1);
  add(322, long, 1, tile);
  add(323, long, 1, tile);
  // A single value is stored in the entry itself, not behind an offset.
  add(324, long, count, count == 1 ? dataOffset : offsetsOffset);
  add(325, long, count, count == 1 ? tiles.single.length : countsOffset);
  return out;
}

Future<void> _settle(WidgetTester tester, {int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Rgb> _pixel(WidgetTester tester, Offset local) async {
  final element = tester.element(find.byKey(_boundaryKey));
  final image = (await tester.runAsync(() => captureImage(element)))!;
  final data = (await tester.runAsync(() => image.toByteData()))!;
  final i = (local.dy.floor() * image.width + local.dx.floor()) * 4;
  return (data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
}

Matcher _near(_Rgb expected, {int tolerance = 60}) => predicate<_Rgb>(
  (c) =>
      (c.$1 - expected.$1).abs() <= tolerance &&
      (c.$2 - expected.$2).abs() <= tolerance &&
      (c.$3 - expected.$3).abs() <= tolerance,
  'within $tolerance of $expected',
);

void main() {
  group('TiffImage.readTileJpeg', () {
    test('returns each tile as a standalone JPEG, null when sparse', () {
      final page = TiffDecoder.decode(
        _jpegTiff(
          width: 128,
          height: 64,
          tile: 64,
          color: (tx, ty) => tx == 0 ? _red : _blue,
          sparse: {(1, 0)},
        ),
      ).images.single;

      final jpeg = page.readTileJpeg(0, 0)!;
      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
      expect(jpeg.sublist(jpeg.length - 2), [0xFF, 0xD9]);
      final decoded = img.decodeJpg(jpeg)!;
      final pixel = decoded.getPixel(32, 32);
      expect((pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()), _near(_red));

      expect(page.readTileJpeg(1, 0), isNull);
      expect(() => page.readTileJpeg(2, 0), throwsRangeError);
    });

    test('marks RGB-photometric tiles as untransformed', () {
      final page = TiffDecoder.decode(
        _jpegTiff(
          width: 64,
          height: 64,
          tile: 64,
          color: (_, _) => _red,
          photometric: 2,
        ),
      ).images.single;
      expect(page.readTileJpeg(0, 0)!.sublist(2, 4), [0xFF, 0xEE]);
    });

    test('rejects pages that are not JPEG-tiled', () {
      final page = TiffDecoder.decode(
        TiffEncoder.encode([
          TiffImageSpec(
            width: 4,
            height: 4,
            samplesPerPixel: 1,
            bitsPerSample: 8,
            photometric: TiffPhotometric.blackIsZero,
            samples: Uint8List(16),
            tileWidth: 4,
            tileLength: 4,
          ),
        ]),
      ).images.single;
      expect(() => page.readTileJpeg(0, 0), throwsA(isA<TiffException>()));
    });
  });

  testWidgets('JPEG tiles are decoded natively, alone and as composites', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('tiff_native_jpeg');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/jpeg.tif')
      ..writeAsBytesSync(
        _jpegTiff(
          width: 8192,
          height: 512,
          tile: 64,
          color: (tx, ty) => tx < 64 ? _red : _blue,
        ),
      );
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TransformationController();
    // No JPEG decoder is set up in the workers: only the native path can
    // show these tiles.
    await tester.runAsync(
      () => tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: _boundaryKey,
              child: SizedBox.fromSize(
                size: _viewport,
                child: TiffImageView(
                  filePath: file.path,
                  controller: controller,
                  showMinimap: false,
                  showLoadingIndicator: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);

    // Fully zoomed out: 64px tiles drawn 6px wide, merged into composites.
    expect(await _pixel(tester, const Offset(200, 200)), _near(_red));
    expect(await _pixel(tester, const Offset(600, 200)), _near(_blue));

    Matrix4 viewAt(double scale) => Matrix4.identity()
      ..translateByDouble(400 - 4096 * scale, 200 - 256 * scale, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);

    // Just under native size: 2x2-tile composites at full resolution.
    controller.value = viewAt(0.9);
    await _settle(tester);
    expect(await _pixel(tester, const Offset(390, 200)), _near(_red));
    expect(await _pixel(tester, const Offset(410, 200)), _near(_blue));

    // Zoomed in: single tiles.
    controller.value = viewAt(2);
    await _settle(tester);
    expect(await _pixel(tester, const Offset(390, 200)), _near(_red));
    expect(await _pixel(tester, const Offset(410, 200)), _near(_blue));
    expect(tester.takeException(), isNull);
  });
}
