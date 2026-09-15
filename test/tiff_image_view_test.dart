import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_minimap.dart';
import 'package:tiff/tiff_viewer.dart';

const _viewport = Size(800, 400);
const _boundaryKey = Key('boundary');

typedef _Rgb = (int, int, int);

/// Vertical stripes one [period] wide: red where `x ~/ period` is even, blue
/// where it's odd.
TiffImageSpec _stripes(int width, int height, {int period = 1, int? tile}) {
  final samples = Uint8List(width * height * 3);
  for (var x = 0; x < width; x++) {
    if ((x ~/ period).isEven) {
      for (var y = 0; y < height; y++) {
        samples[(y * width + x) * 3] = 255;
      }
    } else {
      for (var y = 0; y < height; y++) {
        samples[(y * width + x) * 3 + 2] = 255;
      }
    }
  }
  return _spec(width, height, samples, tile);
}

TiffImageSpec _solid(int width, int height, _Rgb color, {int? tile}) {
  final samples = Uint8List(width * height * 3);
  for (var i = 0; i < samples.length; i += 3) {
    samples[i] = color.$1;
    samples[i + 1] = color.$2;
    samples[i + 2] = color.$3;
  }
  return _spec(width, height, samples, tile);
}

TiffImageSpec _spec(int width, int height, Uint8List samples, int? tile) =>
    TiffImageSpec(
      width: width,
      height: height,
      samplesPerPixel: 3,
      bitsPerSample: 8,
      photometric: TiffPhotometric.rgb,
      samples: samples,
      tileWidth: tile,
      tileLength: tile,
    );

String _write(Directory dir, List<TiffImageSpec> specs) {
  final file = File('${dir.path}/image_${dir.listSync().length}.tif');
  file.writeAsBytesSync(TiffEncoder.encode(specs));
  return file.path;
}

/// Worker isolates and image decodes finish in real time; the view's debounce
/// timer runs on the fake test clock — so alternate both.
Future<void> _settle(WidgetTester tester, {int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpView(
  WidgetTester tester,
  TiffImageView view, {
  double devicePixelRatio = 1,
}) async {
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(
    () => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: _boundaryKey,
            child: SizedBox.fromSize(size: _viewport, child: view),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// Shows base point [center] at the middle of the viewport at [scale].
Matrix4 _viewAt(double scale, Offset center) => Matrix4.identity()
  ..translateByDouble(
    _viewport.width / 2 - center.dx * scale,
    _viewport.height / 2 - center.dy * scale,
    0,
    1,
  )
  ..scaleByDouble(scale, scale, scale, 1);

/// The color actually rendered at [local] (viewport coordinates).
Future<_Rgb> _pixel(WidgetTester tester, Offset local) async {
  final element = tester.element(find.byKey(_boundaryKey));
  final image = (await tester.runAsync(() => captureImage(element)))!;
  final data = (await tester.runAsync(() => image.toByteData()))!;
  final i = (local.dy.floor() * image.width + local.dx.floor()) * 4;
  return (data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
}

Matcher _near(_Rgb expected, {int tolerance = 50}) => predicate<_Rgb>(
  (c) =>
      (c.$1 - expected.$1).abs() <= tolerance &&
      (c.$2 - expected.$2).abs() <= tolerance &&
      (c.$3 - expected.$3).abs() <= tolerance,
  'within $tolerance of $expected',
);

const _red = (255, 0, 0);
const _blue = (0, 0, 255);
const _green = (0, 255, 0);

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('tiff_view'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  TiffImageView view(
    String path, {
    TransformationController? controller,
    double brightness = 0,
    ValueChanged<Object>? onError,
  }) => TiffImageView(
    filePath: path,
    controller: controller,
    brightness: brightness,
    showMinimap: false,
    showLoadingIndicator: false,
    onError: onError,
  );

  // 1-px stripes: the overview (box-filtered to half size) is uniformly
  // purple, so red and blue side by side prove real tile detail was painted.
  for (final (label, tile) in [('tiled', 256), ('strip-organized', null)]) {
    testWidgets('$label page: overview when zoomed out, full detail when in', (
      tester,
    ) async {
      final path = _write(tempDir, [_stripes(8192, 512, tile: tile)]);
      final controller = TransformationController();
      await _pumpView(tester, view(path, controller: controller));

      expect(
        await _pixel(tester, const Offset(400, 200)),
        _near((128, 0, 128)),
      );

      controller.value = _viewAt(4, const Offset(4096, 256));
      await _settle(tester);

      // Each base pixel spans 4 screen pixels; x=4096 starts at screen x=400.
      // For strips this also crosses the boundary between two band columns.
      expect(await _pixel(tester, const Offset(398, 200)), _near(_blue));
      expect(await _pixel(tester, const Offset(402, 200)), _near(_red));
      expect(await _pixel(tester, const Offset(406, 200)), _near(_blue));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tiny tiles are loaded as composites that keep full detail', (
    tester,
  ) async {
    // 8x8 tiles drawn 24px wide get merged into composites.
    final path = _write(tempDir, [_stripes(16384, 32, tile: 8)]);
    final controller = TransformationController();
    await _pumpView(tester, view(path, controller: controller));

    controller.value = _viewAt(3, const Offset(8192, 16));
    await _settle(tester);

    expect(await _pixel(tester, const Offset(401, 200)), _near(_red));
    expect(await _pixel(tester, const Offset(404, 200)), _near(_blue));
  });

  testWidgets('pages that are smaller copies are used as pyramid rungs', (
    tester,
  ) async {
    final path = _write(tempDir, [
      _stripes(16384, 128, tile: 256),
      _solid(64, 64, (255, 255, 0)), // unrelated label image
      _solid(8192, 64, _green, tile: 256),
      _solid(4096, 32, _blue, tile: 256),
    ]);
    final controller = TransformationController();
    await _pumpView(tester, view(path, controller: controller));

    // Fully zoomed out: the overview, derived from the 4096-wide rung.
    expect(await _pixel(tester, const Offset(400, 200)), _near(_blue));

    // At half size the 8192-wide rung is sharp enough — its tiles show.
    controller.value = _viewAt(0.5, const Offset(8192, 64));
    await _settle(tester);
    expect(await _pixel(tester, const Offset(400, 200)), _near(_green));

    // Zoomed in past native size: the base page's own stripes.
    controller.value = _viewAt(4, const Offset(8192, 64));
    await _settle(tester);
    expect(await _pixel(tester, const Offset(402, 200)), _near(_red));
    expect(await _pixel(tester, const Offset(406, 200)), _near(_blue));
  });

  testWidgets('while a rung loads, every cached rung shows, coarsest first', (
    tester,
  ) async {
    const yellow = (255, 255, 0);
    final bytes = TiffEncoder.encode([
      TiffImageSpec(
        width: 5120,
        height: 256,
        samplesPerPixel: 3,
        bitsPerSample: 8,
        photometric: TiffPhotometric.rgb,
        samples: Uint8List(5120 * 256 * 3),
        tileWidth: 256,
        tileLength: 256,
        compression: 8,
      ),
      _solid(2560, 128, _green, tile: 256),
      _solid(1280, 64, _blue, tile: 256), // the preview's source
      _solid(640, 32, yellow, tile: 256), // what the fitted view loads
    ]);
    // Corrupt every base tile, so the base rung never finishes loading.
    final base = TiffDecoder.decode(bytes).images.first.metadata;
    for (var i = 0; i < base.tileOffsets!.length; i++) {
      final start = base.tileOffsets![i];
      bytes.fillRange(start, start + base.tileByteCounts![i], 0xFF);
    }
    final path = '${tempDir.path}/corrupt_base.tif';
    File(path).writeAsBytesSync(bytes);
    final controller = TransformationController();
    await _pumpView(tester, view(path, controller: controller));

    // Fitted: the whole yellow rung loads.
    expect(await _pixel(tester, const Offset(400, 200)), _near(yellow));

    // Half size around x = 1000: green loads for base x 0..2560 only.
    controller.value = _viewAt(0.5, const Offset(1000, 128));
    await _settle(tester);
    expect(await _pixel(tester, const Offset(400, 200)), _near(_green));

    // Zoomed in across green's edge: green on its side, yellow — not the
    // blue preview — beyond it.
    controller.value = _viewAt(4, const Offset(2560, 128));
    await _settle(tester);
    expect(await _pixel(tester, const Offset(300, 200)), _near(_green));
    expect(await _pixel(tester, const Offset(500, 200)), _near(yellow));
  });

  testWidgets('the minimap picks up loaded tiles over its preview', (
    tester,
  ) async {
    const yellow = (255, 255, 0);
    final path = _write(tempDir, [
      _solid(5120, 256, _red, tile: 256),
      _solid(2560, 128, _green, tile: 256),
      _solid(1280, 64, _blue, tile: 256), // the preview's source
      _solid(640, 32, yellow, tile: 256), // what the fitted view loads
    ]);
    final controller = TransformationController();
    await _pumpView(
      tester,
      TiffImageView(
        filePath: path,
        controller: controller,
        showLoadingIndicator: false,
      ),
    );

    // The minimap image spans the 5120-wide page in 512 pixels.
    Future<_Rgb> minimapPixel(int x) async {
      final image = tester
          .widget<TiffMinimap>(find.byType(TiffMinimap))
          .overview!;
      expect(image.width, 512);
      final data = (await tester.runAsync(() => image.toByteData()))!;
      final i = (image.height ~/ 2 * image.width + x) * 4;
      return (data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
    }

    expect(await minimapPixel(400), _near(yellow));

    // Half size around base x = 1000 loads green for base x 0..2560 only.
    controller.value = _viewAt(0.5, const Offset(1000, 128));
    await _settle(tester);
    expect(await minimapPixel(100), _near(_green));
    expect(await minimapPixel(400), _near(yellow));
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('L1 · 1/2'), findsOneWidget);
  });

  testWidgets('a denser screen loads a sharper rung at the same zoom', (
    tester,
  ) async {
    final path = _write(tempDir, [
      _stripes(16384, 128, tile: 256),
      _solid(8192, 64, _green, tile: 256),
    ]);
    final controller = TransformationController();
    await _pumpView(
      tester,
      view(path, controller: controller),
      devicePixelRatio: 2,
    );

    // At half size on a 2x screen, the green 8192-wide rung would stretch
    // each texel over 2 physical pixels — the base page is loaded instead.
    controller.value = _viewAt(0.5, const Offset(8192, 64));
    await _settle(tester);
    expect(
      await _pixel(tester, const Offset(400, 200)),
      _near((128, 0, 128), tolerance: 80),
    );
  });

  testWidgets('changing brightness re-renders the adjusted pixels', (
    tester,
  ) async {
    final path = _write(tempDir, [_solid(1024, 1024, _red, tile: 256)]);
    await _pumpView(tester, view(path));
    expect(await _pixel(tester, const Offset(400, 200)), _near(_red));

    await _pumpView(tester, view(path, brightness: -255));
    expect(await _pixel(tester, const Offset(400, 200)), _near((0, 0, 0)));
  });

  testWidgets('the mouse wheel zooms around the pointer', (tester) async {
    final path = _write(tempDir, [_solid(1024, 1024, _red, tile: 256)]);
    final controller = TransformationController();
    await _pumpView(tester, view(path, controller: controller));
    final before = controller.value.getMaxScaleOnAxis();

    final center = tester.getCenter(find.byKey(_boundaryKey));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(
      pointer.scroll(Offset(0, -200 * math.log(2))),
    );
    await tester.pump();

    expect(controller.value.getMaxScaleOnAxis(), closeTo(before * 2, 1e-6));
  });

  testWidgets('an unreadable file is reported through onError', (tester) async {
    Object? error;
    await _pumpView(
      tester,
      view('${tempDir.path}/missing.tif', onError: (e) => error = e),
    );
    expect(error, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
