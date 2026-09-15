import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../region/tiff_initial_view.dart';
import '../widgets/tiff_minimap.dart';
import 'lod_engine.dart';

/// Where a [TiffImageView] starts when it opens (and after its source
/// changes).
enum TiffImageViewStart {
  /// The whole page, scaled down to fit the viewport and centered.
  fit,

  /// A region at the center of the page, sized for the viewport and device
  /// pixel ratio — see [TiffInitialView.forViewport].
  centeredRegion,
}

/// A pannable, zoomable view of one page of a TIFF/BigTIFF file of any size
/// — the counterpart to `package:svs`'s `SvsImageView`.
///
/// Only the tiles needed for the current viewport and zoom are decoded, on a
/// pool of background isolates, and decoded tiles are kept in a byte-bounded
/// LRU cache ([cacheBytes]):
///
/// * The page's own pyramid (every other page that is a smaller copy of
///   page [pageIndex]) and, optionally, a sidecar of extra rungs
///   ([pyramidLevelsPath]) are used, always loading only the one rung that
///   matches the zoom. Rungs already cached — or a box-filtered overview —
///   are painted underneath while it loads, so zooming sharpens a preview
///   instead of flashing blank.
/// * A zoomed-out view of a page with too shallow a pyramid loads composites
///   of many tiles, downscaled in the worker, so the tile count and texture
///   memory follow the screen size rather than the page size.
/// * A strip-organized page is served as strip-aligned bands, so no strip is
///   decompressed more often than it has to be.
/// * Painting happens in screen space and visits only on-screen tiles.
///
/// The view state lives in a [TransformationController] ([controller], or an
/// internal one) holding a uniform scale plus translation: image point `p`
/// shows at screen point `p * scale + translation`. Read it to build
/// overlays (a scale bar, a zoom readout), or set it to navigate —
/// [TiffMinimap] works with it directly.
///
/// Reads the file with `dart:io` on worker isolates, so it is not available
/// on the web. Needs bounded constraints (e.g. a `SizedBox` or `Expanded`).
class TiffImageView extends StatefulWidget {
  /// Path of the TIFF/BigTIFF file. Every worker isolate opens its own
  /// handle on it.
  final String filePath;

  /// The page to show — its full-resolution base rung.
  final int pageIndex;

  /// Optional sidecar TIFF whose pages are extra, smaller rungs of the page
  /// — e.g. the output of
  /// `TiffDisplayOptimizer.optimizeLargeSourcePyramidLevels` for a page with
  /// no pyramid of its own. Pages whose aspect ratio doesn't match are
  /// ignored.
  final String? pyramidLevelsPath;

  /// Called once in every worker isolate before it decodes anything — pass
  /// `TiffImageAdapter.enableJpegSupport` for JPEG-compressed files. Must be
  /// a static or top-level function (a closure over local state can't cross
  /// an isolate boundary).
  final void Function()? setUpIsolate;

  /// Holds the view transform; see the class doc comment. Left null, the
  /// view owns one internally.
  final TransformationController? controller;

  final TiffImageViewStart initialView;

  /// Screen pixels per base pixel the user may zoom in to.
  final double maxScale;

  /// How far a rung's texels may be stretched on screen before the next,
  /// sharper rung is loaded instead.
  final double maxUpsample;

  /// Brightness/contrast/gamma applied to every decoded pixel — see
  /// `ImageAdjustments.apply`. Changing them re-decodes what's on screen;
  /// the old pixels stay visible until the new ones arrive.
  final double brightness;
  final double contrast;
  final double gamma;

  /// Decoded-pixel byte budget of the tile cache.
  final int cacheBytes;

  /// Worker isolates decoding tiles; null picks one per CPU core minus one,
  /// capped at 4.
  final int? workerCount;

  /// Whether a [TiffMinimap] shows in the bottom-right corner.
  final bool showMinimap;

  /// Whether a small progress indicator shows in the top-left corner while
  /// tiles are loading.
  final bool showLoadingIndicator;

  /// Fills everything not covered by image pixels.
  final Color backgroundColor;

  /// Called when the file can't be opened or shown. Nothing is painted in
  /// that case besides [backgroundColor].
  final ValueChanged<Object>? onError;

  const TiffImageView({
    super.key,
    required this.filePath,
    this.pageIndex = 0,
    this.pyramidLevelsPath,
    this.setUpIsolate,
    this.controller,
    this.initialView = TiffImageViewStart.fit,
    this.maxScale = 40,
    this.maxUpsample = 1.3,
    this.brightness = 0,
    this.contrast = 1,
    this.gamma = 1,
    this.cacheBytes = 256 * 1024 * 1024,
    this.workerCount,
    this.showMinimap = true,
    this.showLoadingIndicator = true,
    this.backgroundColor = const Color(0xFFE0E0E0),
    this.onError,
  }) : assert(gamma > 0),
       assert(maxUpsample >= 1),
       assert(cacheBytes > 0),
       assert(workerCount == null || workerCount > 0);

  @override
  State<TiffImageView> createState() => TiffImageViewState();
}

/// State of a [TiffImageView] — reach it through a `GlobalKey` to call
/// [resetView] or read [imageSize].
class TiffImageViewState extends State<TiffImageView>
    with WidgetsBindingObserver {
  late LodEngine _engine;
  TransformationController? _ownController;
  Size? _viewportSize;
  bool _initialized = false;
  Object? _reportedError;

  double _gestureStartScale = 1;
  Offset _gestureStartOrigin = Offset.zero;
  Offset _gestureStartFocalPoint = Offset.zero;

  TransformationController get _controller =>
      widget.controller ?? (_ownController ??= TransformationController());

  double get _scale => _controller.value.getMaxScaleOnAxis();

  /// The base-image point shown at the viewport's top-left corner.
  Offset get _origin {
    final translation = _controller.value.getTranslation();
    final scale = _scale;
    return Offset(-translation.x / scale, -translation.y / scale);
  }

  /// The page's full-resolution size, once the file has been opened.
  Size? get imageSize {
    final base = _engine.baseMetadata;
    return base == null
        ? null
        : Size(base.width.toDouble(), base.height.toDouble());
  }

  /// Fits the whole page to the viewport again.
  void resetView() {
    final viewportSize = _viewportSize;
    if (viewportSize == null || viewportSize.isEmpty || !_engine.isReady) {
      return;
    }
    _fit(viewportSize);
    _engine.flushNow(viewportSize, _scale, _origin);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onViewChanged);
    _startEngine();
  }

  void _startEngine() {
    _initialized = false;
    _reportedError = null;
    _engine =
        LodEngine(
            source: (
              filePath: widget.filePath,
              pageIndex: widget.pageIndex,
              pyramidLevelsPath: widget.pyramidLevelsPath,
              setUpIsolate: widget.setUpIsolate,
            ),
            workerCount: widget.workerCount,
            cacheBytes: widget.cacheBytes,
            maxUpsample: widget.maxUpsample,
          )
          ..setAdjustments(
            brightness: widget.brightness,
            contrast: widget.contrast,
            gamma: widget.gamma,
          )
          ..addListener(_onEngineChanged);
    unawaited(_engine.start());
  }

  @override
  void didUpdateWidget(TiffImageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldController = oldWidget.controller ?? _ownController;
    if (!identical(oldController, _controller)) {
      oldController?.removeListener(_onViewChanged);
      _controller.addListener(_onViewChanged);
    }
    if (widget.filePath != oldWidget.filePath ||
        widget.pageIndex != oldWidget.pageIndex ||
        widget.pyramidLevelsPath != oldWidget.pyramidLevelsPath ||
        widget.setUpIsolate != oldWidget.setUpIsolate ||
        widget.workerCount != oldWidget.workerCount ||
        widget.cacheBytes != oldWidget.cacheBytes ||
        widget.maxUpsample != oldWidget.maxUpsample) {
      _engine
        ..removeListener(_onEngineChanged)
        ..dispose();
      _startEngine();
    } else {
      _engine.setAdjustments(
        brightness: widget.brightness,
        contrast: widget.contrast,
        gamma: widget.gamma,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onViewChanged);
    _engine
      ..removeListener(_onEngineChanged)
      ..dispose();
    _ownController?.dispose();
    super.dispose();
  }

  /// Decoded tiles are exactly what the OS wants freed — cheaply reloaded
  /// later — so drop them rather than risk the app being killed for a cache.
  @override
  void didHaveMemoryPressure() => _engine.handleMemoryPressure();

  void _onEngineChanged() {
    if (!mounted) return;
    final error = _engine.error;
    if (error != null && !identical(error, _reportedError)) {
      _reportedError = error;
      widget.onError?.call(error);
    }
    final viewportSize = _viewportSize;
    if (!_initialized && _engine.isReady && viewportSize != null) {
      _initialize(viewportSize);
    }
    setState(() {});
  }

  /// Every transform change — gestures, the minimap, the app setting the
  /// controller — flows through here into the engine's debounced tile
  /// selection.
  void _onViewChanged() {
    final viewportSize = _viewportSize;
    if (!_initialized || viewportSize == null) return;
    _engine.onViewportChanged(viewportSize, _scale, _origin);
  }

  void _setView(double scale, Offset origin) {
    _controller.value = Matrix4.identity()
      ..translateByDouble(-origin.dx * scale, -origin.dy * scale, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  double _fitScale(Size viewportSize) {
    final base = _engine.baseMetadata!;
    return math.min(
      viewportSize.width / base.width,
      viewportSize.height / base.height,
    );
  }

  void _fit(Size viewportSize) {
    final base = _engine.baseMetadata!;
    final scale = _fitScale(viewportSize);
    _setView(
      scale,
      Offset(
        (base.width - viewportSize.width / scale) / 2,
        (base.height - viewportSize.height / scale) / 2,
      ),
    );
  }

  void _initialize(Size viewportSize) {
    if (viewportSize.isEmpty) return;
    switch (widget.initialView) {
      case TiffImageViewStart.fit:
        _fit(viewportSize);
      case TiffImageViewStart.centeredRegion:
        final devicePixelRatio =
            MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
        final view = TiffInitialView.forViewport(
          _engine.baseMetadata!,
          viewportWidth: viewportSize.width,
          viewportHeight: viewportSize.height,
          devicePixelRatio: devicePixelRatio,
        );
        final scale = view.zoom / devicePixelRatio;
        final region = view.region;
        final center = Offset(
          region.x + region.width / 2,
          region.y + region.height / 2,
        );
        _setView(
          scale,
          center -
              Offset(viewportSize.width, viewportSize.height) / (2 * scale),
        );
    }
    _initialized = true;
    _engine.flushNow(viewportSize, _scale, _origin);
  }

  /// Keeps the image point under [startFocalPoint] (at [startScale]/
  /// [startOrigin]) pinned under [currentFocalPoint] at the new scale — the
  /// shared math behind pinch zoom, wheel zoom, and pan.
  void _zoomAndPanTo({
    required double startScale,
    required Offset startOrigin,
    required Offset startFocalPoint,
    required Offset currentFocalPoint,
    required double scaleMultiplier,
  }) {
    final viewportSize = _viewportSize;
    if (!_initialized || viewportSize == null) return;
    final focalImagePoint = startOrigin + startFocalPoint / startScale;
    final minScale = _fitScale(viewportSize) / 2;
    final newScale = (startScale * scaleMultiplier)
        .clamp(minScale, math.max(minScale, widget.maxScale))
        .toDouble();
    _setView(newScale, focalImagePoint - currentFocalPoint / newScale);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartScale = _scale;
    _gestureStartOrigin = _origin;
    _gestureStartFocalPoint = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    _zoomAndPanTo(
      startScale: _gestureStartScale,
      startOrigin: _gestureStartOrigin,
      startFocalPoint: _gestureStartFocalPoint,
      currentFocalPoint: details.localFocalPoint,
      scaleMultiplier: details.scale,
    );
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final viewportSize = _viewportSize;
    if (_initialized && viewportSize != null) {
      _engine.flushNow(viewportSize, _scale, _origin);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Claimed through the resolver so an enclosing scrollable doesn't also
    // scroll while the wheel zooms the image.
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final scroll = event as PointerScrollEvent;
      _zoomAndPanTo(
        startScale: _scale,
        startOrigin: _origin,
        startFocalPoint: scroll.localPosition,
        currentFocalPoint: scroll.localPosition,
        scaleMultiplier: math.exp(-scroll.scrollDelta.dy / 200),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        assert(
          constraints.hasBoundedWidth && constraints.hasBoundedHeight,
          'TiffImageView needs a bounded size — wrap it in a SizedBox, '
          'Expanded, or similar.',
        );
        final viewportSize = constraints.biggest;
        final devicePixelRatio =
            MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
        _engine.setDevicePixelRatio(devicePixelRatio);
        if (_viewportSize != viewportSize) {
          _viewportSize = viewportSize;
          // The transform can't change mid-layout: its listeners (the
          // minimap, app overlays) would be marked dirty during this frame.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _viewportSize != viewportSize) return;
            if (!_initialized) {
              if (_engine.isReady) setState(() => _initialize(viewportSize));
            } else {
              _engine.flushNow(viewportSize, _scale, _origin);
            }
          });
        }
        final engine = _engine;
        final base = engine.baseMetadata;
        return ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: widget.backgroundColor,
                  child: Listener(
                    onPointerSignal: _onPointerSignal,
                    child: GestureDetector(
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onScaleEnd: _onScaleEnd,
                      child: CustomPaint(
                        size: viewportSize,
                        painter: _TiffImagePainter(
                          engine,
                          _controller,
                          initialized: _initialized,
                          devicePixelRatio: devicePixelRatio,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.showLoadingIndicator &&
                  engine.error == null &&
                  (!_initialized || engine.isWorking))
                const Positioned(
                  top: 8,
                  left: 8,
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (widget.showMinimap && base != null && _initialized)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: TiffMinimap(
                    overview: engine.minimapImage,
                    baseWidth: base.width,
                    baseHeight: base.height,
                    controller: _controller,
                    viewportSize: viewportSize,
                    levelLabel: (scale) => _levelLabel(engine, scale),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The level [engine] shows at [scale], e.g. "L2 · 1/4" — "L0 · 1:1" is the
/// page at full resolution.
String? _levelLabel(LodEngine engine, double scale) {
  final level = engine.levelAt(scale);
  if (level == null) return null;
  final (index, downsample) = level;
  final ratio = downsample.round() <= 1
      ? '1:1'
      : '1/${downsample < 10 ? downsample.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '') : downsample.round()}';
  return 'L$index · $ratio';
}

/// Repaints on every transform change and every tile the engine delivers —
/// cheap, since [LodEngine.paint] only ever visits on-screen tiles.
class _TiffImagePainter extends CustomPainter {
  final LodEngine engine;
  final TransformationController controller;
  final bool initialized;

  /// Only compared, so moving to a screen with a different density — which
  /// changes the level [LodEngine.paint] picks — repaints.
  final double devicePixelRatio;

  _TiffImagePainter(
    this.engine,
    this.controller, {
    required this.initialized,
    required this.devicePixelRatio,
  }) : super(repaint: Listenable.merge([engine, controller]));

  @override
  void paint(Canvas canvas, Size size) {
    if (!initialized) return;
    final transform = controller.value;
    final scale = transform.getMaxScaleOnAxis();
    final translation = transform.getTranslation();
    engine.paint(
      canvas,
      size,
      scale,
      Offset(-translation.x / scale, -translation.y / scale),
    );
  }

  @override
  bool shouldRepaint(covariant _TiffImagePainter oldDelegate) =>
      oldDelegate.engine != engine ||
      oldDelegate.controller != controller ||
      oldDelegate.initialized != initialized ||
      oldDelegate.devicePixelRatio != devicePixelRatio;
}
