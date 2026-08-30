import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiff/tiff_minimap.dart';

// decodeImageFromPixels completes via a real engine callback, which the
// ambient FakeAsync test zone `testWidgets` normally runs in never observes
// — both creating the Future *and* awaiting it have to happen inside
// runAsync(), or the await hangs until flutter_test's own outer timeout
// kills the test.
Future<ui.Image> _solidImage(
  WidgetTester tester,
  int width,
  int height,
  int r,
  int g,
  int b,
) async {
  final image = await tester.runAsync(() {
    final bytes = Uint8List(width * height * 4);
    for (var i = 0; i < bytes.length; i += 4) {
      bytes[i] = r;
      bytes[i + 1] = g;
      bytes[i + 2] = b;
      bytes[i + 3] = 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  });
  return image!;
}

void main() {
  testWidgets('shows a placeholder spinner while overview is null', (
    tester,
  ) async {
    final controller = TransformationController();
    await tester.pumpWidget(
      MaterialApp(
        home: TiffMinimap(
          overview: null,
          baseWidth: 1000,
          baseHeight: 800,
          controller: controller,
          viewportSize: const Size(400, 300),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
  });

  // Regression test for the bug where RawImage had no `fit`, so it painted
  // the overview at its own native pixel size (centered in a width/height
  // box sized to the *full* base image) instead of stretching to fill —
  // rendering as a near-invisible speck rather than a visible thumbnail.
  testWidgets('renders the overview stretched to fill via BoxFit.fill', (
    tester,
  ) async {
    final overview = await _solidImage(tester, 64, 48, 0, 0, 255);
    final controller = TransformationController();
    await tester.pumpWidget(
      MaterialApp(
        home: TiffMinimap(
          overview: overview,
          baseWidth: 131072,
          baseHeight: 100352,
          controller: controller,
          viewportSize: const Size(400, 300),
        ),
      ),
    );

    final rawImage = tester.widget<RawImage>(find.byType(RawImage));
    expect(rawImage.image, same(overview));
    expect(
      rawImage.fit,
      BoxFit.fill,
      reason:
          'without fill, a small overview renders as an invisible speck rather than filling the box',
    );
  });

  testWidgets('the viewport rectangle follows the controller transform', (
    tester,
  ) async {
    final overview = await _solidImage(tester, 32, 32, 255, 0, 0);
    final controller = TransformationController();
    await tester.pumpWidget(
      MaterialApp(
        home: TiffMinimap(
          overview: overview,
          baseWidth: 1000,
          baseHeight: 1000,
          controller: controller,
          viewportSize: const Size(400, 300),
        ),
      ),
    );

    CustomPaint paintWidget() =>
        tester.widget<CustomPaint>(find.byType(CustomPaint).last);
    final initialPainter = paintWidget().painter as dynamic;
    final initialRect = initialPainter.rect as Rect;

    controller.value = Matrix4.identity()..scaleByDouble(2, 2, 2, 1);
    await tester.pump();

    final updatedPainter = paintWidget().painter as dynamic;
    final updatedRect = updatedPainter.rect as Rect;
    expect(updatedRect, isNot(equals(initialRect)));
  });

  testWidgets(
    'tapping the minimap re-centers the controller on that image point',
    (tester) async {
      final overview = await _solidImage(tester, 32, 32, 0, 255, 0);
      final controller = TransformationController();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: TiffMinimap(
              overview: overview,
              baseWidth: 1000,
              baseHeight: 1000,
              controller: controller,
              viewportSize: const Size(400, 300),
            ),
          ),
        ),
      );

      final before = controller.value.clone();
      await tester.tapAt(tester.getCenter(find.byType(GestureDetector)));
      await tester.pump();

      expect(controller.value, isNot(equals(before)));
    },
  );

  testWidgets('onNavigate overrides the default recenter-controller behavior', (
    tester,
  ) async {
    final overview = await _solidImage(tester, 32, 32, 255, 165, 0);
    final controller = TransformationController();
    Offset? navigatedTo;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: TiffMinimap(
            overview: overview,
            baseWidth: 1000,
            baseHeight: 1000,
            controller: controller,
            viewportSize: const Size(400, 300),
            onNavigate: (p) => navigatedTo = p,
          ),
        ),
      ),
    );

    final before = controller.value.clone();
    await tester.tapAt(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump();

    expect(navigatedTo, isNotNull);
    expect(
      controller.value,
      equals(before),
      reason:
          'onNavigate being set means the widget must not also mutate the controller itself',
    );
  });
}
