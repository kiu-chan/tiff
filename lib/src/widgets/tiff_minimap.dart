import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A small overview of a whole [TiffImage] page with a rectangle marking the
/// area currently visible in some other, zoomed-in viewer (an
/// `InteractiveViewer` driven by [controller]) — tap or drag on it to jump
/// there.
///
/// This widget is deliberately decode-agnostic: it draws whatever
/// already-decoded [overview] bitmap it's given (see the `tiff_io.dart`
/// `TiffParallelDecoder`, or a plain `TiffImage.decodeRegionRgba8` call, for
/// how to produce one — typically a capped-size downsample of the smallest
/// pyramid rung at or above the size you want the minimap to render at) —
/// it never touches a [TiffImage] or spawns a decode itself, so it fits
/// whatever tiled/banded/isolate-based loading strategy the caller already
/// has, rather than assuming one.
///
/// [overview] may be smaller (in actual decoded pixels) than [baseWidth]/
/// [baseHeight] — the *native* full-resolution page dimensions, used only to
/// size the viewport-rect overlay in the same coordinate space [controller]
/// operates in. [overview] is stretched to fill this widget's [size]
/// regardless of its own resolution.
class TiffMinimap extends StatelessWidget {
  /// The already-decoded overview bitmap, or `null` while one is still being
  /// produced — a small spinner is shown in its place.
  final ui.Image? overview;

  /// The full page's native width, in the same coordinate space
  /// [controller]'s transform operates in (i.e. what an `InteractiveViewer`
  /// wrapping a [baseWidth] x [baseHeight] child would use).
  final int baseWidth;

  /// The full page's native height — see [baseWidth].
  final int baseHeight;

  /// The transform of the viewer this minimap overlays — read to draw the
  /// current viewport rectangle, and written (via [onNavigate], or directly
  /// if that's left unset) when the user taps or drags on the minimap.
  final TransformationController controller;

  /// The logical size of the viewer [controller] drives — needed to compute
  /// both the current viewport rectangle and where a tap/drag should
  /// re-center it.
  final Size viewportSize;

  /// The rendered size of the minimap itself. Defaults to a small corner
  /// overlay; pass a larger [Size] for a more prominent one.
  final Size size;

  final Color borderColor;
  final Color backgroundColor;
  final Color viewportRectColor;

  /// Called with an image-space point when the user taps or drags on the
  /// minimap, wanting to jump the viewer there. Left unset, [controller] is
  /// updated directly — recentering the viewer on that point at its current
  /// zoom level — which is the right behavior for a plain `InteractiveViewer`
  /// setup; override it if navigating needs to go through some other state
  /// (e.g. a debounced viewport-request callback) instead.
  final void Function(Offset imagePoint)? onNavigate;

  const TiffMinimap({
    super.key,
    required this.overview,
    required this.baseWidth,
    required this.baseHeight,
    required this.controller,
    required this.viewportSize,
    this.size = const Size(140, 100),
    this.borderColor = const Color(0xB3FFFFFF),
    this.backgroundColor = const Color(0x73000000),
    this.viewportRectColor = const Color(0xFFFF5252),
    this.onNavigate,
  });

  Size get _baseSize => Size(baseWidth.toDouble(), baseHeight.toDouble());

  Rect _visibleImageRect(Matrix4 transform) {
    final baseSize = _baseSize;
    final inverse = Matrix4.copy(transform)..invert();
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero);
    final bottomRight = MatrixUtils.transformPoint(
      inverse,
      Offset(viewportSize.width, viewportSize.height),
    );
    final rect = Rect.fromPoints(topLeft, bottomRight);
    return Rect.fromLTRB(
      rect.left.clamp(0.0, baseSize.width),
      rect.top.clamp(0.0, baseSize.height),
      rect.right.clamp(0.0, baseSize.width),
      rect.bottom.clamp(0.0, baseSize.height),
    );
  }

  void _navigateTo(Offset imagePoint) {
    if (onNavigate != null) {
      onNavigate!(imagePoint);
      return;
    }
    final scale = controller.value.getMaxScaleOnAxis();
    final dx = viewportSize.width / 2 - imagePoint.dx * scale;
    final dy = viewportSize.height / 2 - imagePoint.dy * scale;
    controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  Widget build(BuildContext context) {
    final baseSize = _baseSize;
    return Container(
      width: size.width,
      height: size.height,
      decoration: BoxDecoration(
        border: Border.all(color: borderColor),
        color: backgroundColor,
      ),
      child: overview == null
          ? Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: borderColor,
                ),
              ),
            )
          : AnimatedBuilder(
              animation: controller,
              builder: (context, _) => FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: baseSize.width,
                  height: baseSize.height,
                  child: GestureDetector(
                    onTapUp: (d) => _navigateTo(d.localPosition),
                    onPanUpdate: (d) => _navigateTo(d.localPosition),
                    child: Stack(
                      children: [
                        SizedBox(
                          width: baseSize.width,
                          height: baseSize.height,
                          // fit: BoxFit.fill is required — RawImage with no
                          // `fit` paints at the image's own native pixel
                          // size instead of stretching to width/height, so
                          // without it a small overview (typically far
                          // smaller than baseWidth x baseHeight) renders as
                          // a near-invisible speck in the middle of this
                          // box rather than filling it.
                          child: RawImage(
                            image: overview,
                            width: baseSize.width,
                            height: baseSize.height,
                            fit: BoxFit.fill,
                          ),
                        ),
                        CustomPaint(
                          size: baseSize,
                          painter: _ViewportRectPainter(
                            _visibleImageRect(controller.value),
                            viewportRectColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _ViewportRectPainter extends CustomPainter {
  final Rect rect;
  final Color color;
  _ViewportRectPainter(this.rect, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = (size.longestSide / 150).clamp(1.0, 40.0);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _ViewportRectPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}
