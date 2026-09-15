import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../image/image_metadata.dart';
import '../raster/color/image_adjustments.dart';
import 'lod_worker.dart';
import 'pyramid_source.dart';
import 'tile_cache.dart';
import 'viewport_math.dart';

class _LodWorker {
  ReceivePort? receivePort;
  SendPort? sendPort;
  bool busy = false;

  /// JPEG tile reads sent and not yet answered — see [LodEngine._readJpegs].
  int pendingReads = 0;
}

/// A request sent to a worker, for matching its reply back up. [key] is null
/// for the overview.
class _LodRequest {
  final TileKey? key;
  final int reduction;
  final int version;

  const _LodRequest(this.key, this.reduction, this.version);
}

// Top-level so the closure handed to Isolate.run captures nothing but
// [config] — a closure inside a method can drag unsendable state along.
Future<PyramidSourceInfo> _describeInIsolate(PyramidSourceConfig config) =>
    Isolate.run(() => describePyramidSource(config));

/// Level-of-detail loading and painting for a TIFF page of any size — the
/// engine behind `TiffImageView`, modeled on `package:svs`'s viewer:
///
/// * Only the rung that matches the current zoom is loaded — never every
///   rung from coarse to fine — and while its tiles arrive, the nearest
///   already-cached rung (or the overview) is painted underneath, so a zoom
///   shows a blurry preview that sharpens rather than an empty frame.
/// * The overview counts as a rung of its own: while it is sharp enough for
///   the current zoom, no tile is loaded at all.
/// * A rung whose tiles would be drawn tiny is loaded as composites, and
///   tiles denser than the screen are shrunk in the worker before they reach
///   the GPU (see [selectSpan]/[selectReduction]) — so a viewport's tile
///   count and texture memory follow the screen, not the page.
/// * The wanted set is rebuilt, nearest the viewport center first, on every
///   viewport change; queued work that scrolled away is simply dropped.
/// * Decoded tiles live in a byte-budget LRU [TileCache], and painting only
///   ever visits the tiles on screen.
/// * Like svs, JPEG-tiled rungs skip the Dart decoder: workers only read
///   each tile's standalone JPEG stream, and `dart:ui`'s platform codec
///   decodes it at 1/2 to 1/8 scale — an order of magnitude faster, which is
///   what makes a zoomed-out view of a pyramid-less gigapixel page feasible.
class LodEngine extends ChangeNotifier {
  static const _prefetchMargin = 1;
  static const _maxWantedTiles = 4096;

  /// Share of the cache budget one viewport's tiles may fill — the rest is
  /// headroom for the fallback rung painted underneath while they load.
  static const _cacheBudgetFraction = 0.8;
  static const _memoryPressureCooldown = Duration(seconds: 30);
  static const _maxFailedMemo = 65536;
  static const _debounceDelay = Duration(milliseconds: 80);

  /// One worker per core, leaving one for the UI thread, capped at 4.
  static int get defaultWorkerCount =>
      (Platform.numberOfProcessors - 1).clamp(1, 4);

  final PyramidSourceConfig source;
  final double maxUpsample;
  final TileCache _cache;
  final List<_LodWorker> _workers;

  LodEngine({
    required this.source,
    int? workerCount,
    int cacheBytes = 256 * 1024 * 1024,
    this.maxUpsample = 1.3,
  }) : _cache = TileCache(maxBytes: cacheBytes),
       _workers = List.generate(
         workerCount ?? defaultWorkerCount,
         (_) => _LodWorker(),
       );

  PyramidSourceInfo? _info;
  ui.Image? overview;

  /// The adjustment version [overview]'s pixels were produced under.
  int _overviewVersion = -1;
  bool _overviewWanted = true;
  bool _overviewFailed = false;
  Object? _error;
  bool _disposed = false;

  (Size, double, Offset)? _viewport;
  double _devicePixelRatio = 1;

  /// Whether the wanted tiles come from the in-memory overview, which only
  /// the first worker holds.
  bool _wantedOnFirstWorker = false;
  Timer? _debounce;
  Stopwatch? _memoryPressure;

  Set<TileKey> _wanted = const {};
  int _wantedReduction = 0;
  List<TileKey> _queue = [];
  int _queueHead = 0;
  final _inFlight = <TileKey, _LodRequest>{};
  final _requests = <int, _LodRequest>{};
  final _failed = <TileKey>{};
  int _nextRequestId = 0;
  final _jpegReads = <int, Completer<List<Uint8List?>>>{};
  int _nativeLoads = 0;
  bool _nativePreviewLoading = false;

  /// Whether the wanted tiles are decoded by the platform JPEG codec.
  bool _wantedNative = false;

  /// Native loads spend their time in the platform codec's own thread pool,
  /// not in a worker (which only reads bytes), so they run as parallel as
  /// the CPU allows rather than one per worker.
  late final int _maxNativeLoads = math.max(
    _workers.length,
    Platform.numberOfProcessors,
  );

  int _version = 0;
  double _brightness = 0;
  double _contrast = 1;
  double _gamma = 1;

  /// Whether the source has been opened and described — before this,
  /// [baseMetadata] is null and nothing can be painted.
  bool get isReady => _info != null;

  TiffImageMetadata? get baseMetadata => _info?.base;

  /// The first fatal error (the file couldn't be opened or described, or a
  /// worker couldn't start), if any.
  Object? get error => _error;

  bool get isWorking =>
      _requests.isNotEmpty ||
      _nativeLoads > 0 ||
      (_info == null && _error == null);

  Future<void> start() async {
    try {
      final info = await _describeInIsolate(source);
      if (_disposed) return;
      _info = info;
    } catch (e) {
      _fail(e);
      return;
    }
    notifyListeners();
    _refresh();
    await Future.wait(_workers.map(_startWorker));
  }

  Future<void> _startWorker(_LodWorker worker) async {
    final receivePort = ReceivePort();
    worker.receivePort = receivePort;
    receivePort.listen((message) => _onMessage(worker, message));
    try {
      await Isolate.spawn(lodWorkerEntry, (
        receivePort.sendPort,
        source,
      ), debugName: 'tiff-lod-worker');
    } catch (e) {
      receivePort.close();
      _fail(e);
    }
  }

  void _fail(Object error) {
    if (_disposed) return;
    _error ??= error;
    notifyListeners();
  }

  /// Debounced viewport-change entry point — call on every gesture update,
  /// so a fast pan or pinch doesn't rebuild the wanted set every frame.
  void onViewportChanged(Size viewportSize, double scale, Offset origin) {
    _viewport = (viewportSize, scale, origin);
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, _refresh);
  }

  /// [onViewportChanged] without the debounce — for gesture end, first
  /// layout, and jumps.
  void flushNow(Size viewportSize, double scale, Offset origin) {
    _viewport = (viewportSize, scale, origin);
    _debounce?.cancel();
    _refresh();
  }

  /// Bakes new adjustments into everything loaded from here on. Tiles
  /// already on screen keep showing until their re-adjusted replacements
  /// arrive, rather than flashing back to the overview. Doesn't notify
  /// listeners, so it's safe to call while a widget tree is building.
  void setAdjustments({
    required double brightness,
    required double contrast,
    required double gamma,
  }) {
    if (brightness == _brightness && contrast == _contrast && gamma == _gamma) {
      return;
    }
    _brightness = brightness;
    _contrast = contrast;
    _gamma = gamma;
    _version++;
    // Requests already out still finish, but their stale results are
    // dropped (see _onResult) — so their tiles must be requestable again now.
    _inFlight.clear();
    _overviewWanted = true;
    _refresh();
  }

  double get devicePixelRatio => _devicePixelRatio;

  /// Physical pixels per logical pixel of the screen the page is shown on —
  /// levels are picked so their texels match physical pixels, or a 3x phone
  /// would show the page three times blurrier than it can. Doesn't notify
  /// listeners, so it's safe to call while a widget tree is building.
  void setDevicePixelRatio(double devicePixelRatio) {
    if (devicePixelRatio == _devicePixelRatio || devicePixelRatio <= 0) return;
    _devicePixelRatio = devicePixelRatio;
    _refresh();
  }

  /// The OS asked the app to free memory: drop every decoded tile, and for a
  /// while load with half the budget and no prefetch margin, so refilling
  /// the viewport doesn't immediately climb back to where the signal fired.
  void handleMemoryPressure() {
    _memoryPressure = Stopwatch()..start();
    _cache.clear();
    _refresh();
    notifyListeners();
  }

  bool get _underMemoryPressure {
    final since = _memoryPressure;
    if (since == null) return false;
    if (since.elapsed < _memoryPressureCooldown) return true;
    _memoryPressure = null;
    return false;
  }

  /// The level to show tiles from at [scale]: the coarsest whose texels are
  /// stretched no more than [maxUpsample] over physical pixels, or the base
  /// level when even that must be stretched (deep zoom). As in svs, tiles of
  /// that level are always loaded — the preview is only ever a placeholder.
  int _targetLevelFor(PyramidSourceInfo info, double scale) {
    final physicalScale = scale * _devicePixelRatio;
    var chosen = 0;
    for (var i = 0; i < info.levels.length; i++) {
      final level = info.levels[i];
      if (_overviewFailed && level.rung == overviewRung) continue;
      if (level.downsampleX * physicalScale <= maxUpsample) chosen = i;
    }
    return chosen;
  }

  /// The composite span and reduction [level] is loaded with at [scale] —
  /// the painter must use the same span, or it would look for tiles under
  /// keys nothing ever requested. The span follows logical size (it bounds
  /// the tile count); the reduction follows physical pixels (it bounds
  /// sharpness).
  (int, int) _planFor(LodLevel level, double scale) {
    final screenPixelsPerTexel = level.downsampleX * scale;
    final span = selectSpan(
      math.min(level.tileWidth, level.tileHeight) * screenPixelsPerTexel,
    );
    final reduction = selectReduction(
      screenPixelsPerTexel * _devicePixelRatio,
      maxUpsample: maxUpsample,
      maxReduction: span == 0
          ? _maxNativeReduction
          : level.nativeJpeg
          ? _maxNativeCompositeReduction(level)
          : 16,
    );
    return (span, reduction);
  }

  /// The deepest scale the platform JPEG codec decodes at directly: 1/8.
  static const _maxNativeReduction = 3;

  /// A native composite is drawn from members decoded at up to 1/8 scale;
  /// shrinking it so far that a member lands under 4 pixels would drop
  /// members between pixel centers instead of blending them.
  static int _maxNativeCompositeReduction(LodLevel level) => math.max(
    _maxNativeReduction,
    (math.log(math.min(level.tileWidth, level.tileHeight)) / math.ln2).floor() -
        2,
  );

  void _refresh() {
    final info = _info;
    final viewport = _viewport;
    if (_disposed || info == null || viewport == null) return;
    final (viewportSize, scale, origin) = viewport;
    final target = _targetLevelFor(info, scale);
    final level = info.levels[target];
    final (span, reduction) = _planFor(level, scale);
    final grid = LodGrid(level, span);
    _wantedOnFirstWorker = level.rung == overviewRung;
    _wantedNative = level.nativeJpeg;
    final core = grid.visible(viewportSize, scale, origin);
    if (core == null) {
      _wanted = const {};
      _queue = [];
      _queueHead = 0;
      _pump();
      return;
    }

    final tileBytes =
        reducedExtent(grid.tileWidth, reduction) *
        reducedExtent(grid.tileHeight, reduction) *
        4;
    final pressured = _underMemoryPressure;
    final budgetBytes =
        _cache.maxBytes * _cacheBudgetFraction * (pressured ? 0.5 : 1);
    final limit = math.max(
      1,
      math.min(_maxWantedTiles, budgetBytes ~/ math.max(1, tileBytes)),
    );

    final centerTx =
        (origin.dx + viewportSize.width / (2 * scale)) /
        grid.level.downsampleX /
        grid.tileWidth;
    final centerTy =
        (origin.dy + viewportSize.height / (2 * scale)) /
        grid.level.downsampleY /
        grid.tileHeight;
    final coreTiles = tilesNearestFirst(core, centerTx, centerTy, limit);
    final prefetchRange = grid.visible(
      viewportSize,
      scale,
      origin,
      margin: _prefetchMargin,
    );
    final prefetchTiles =
        pressured || coreTiles.length >= limit || prefetchRange == null
        ? const <(int, int)>[]
        : tilesNearestFirst(
            prefetchRange,
            centerTx,
            centerTy,
            limit - coreTiles.length,
            exclude: core,
          );

    // Insertion-ordered: on-screen tiles nearest the center first, then the
    // prefetch margin — the order workers are handed them in.
    final wanted = <TileKey>{
      for (final (tx, ty) in coreTiles) TileKey(target, tx, ty, grid.span),
      for (final (tx, ty) in prefetchTiles) TileKey(target, tx, ty, grid.span),
    };
    _wanted = wanted;
    _wantedReduction = reduction;
    _queue = [
      for (final key in wanted)
        if (_needsFetch(key, reduction)) key,
    ];
    _queueHead = 0;
    _pump();
  }

  /// Whether [key] still has to be requested to show it at [reduction] with
  /// the current adjustments.
  bool _needsFetch(TileKey key, int reduction) {
    if (_inFlight.containsKey(key) || _failed.contains(key)) return false;
    final cached = _cache.peek(key);
    return cached == null ||
        cached.version != _version ||
        cached.reduction > reduction;
  }

  /// Hands idle workers the preview and then queued tiles, nearest the
  /// viewport center first. Anything cut from the overview goes to the first
  /// worker, the only one that keeps it in memory (see [lodWorkerEntry]).
  void _pump() {
    final info = _info;
    if (_disposed || info == null) return;
    if (_overviewWanted) {
      if (info.overview.sparse && info.levels[info.overview.rung].nativeJpeg) {
        if (_readWorker() != null) {
          _overviewWanted = false;
          unawaited(_loadNativePreview(info));
        }
      } else {
        final worker = _workers.first;
        if (!worker.busy && worker.sendPort != null) {
          _overviewWanted = false;
          _sendPreview(worker, info);
        }
      }
    }
    if (_wantedNative) {
      // The first preview needs only a few hundred decodes and shows the
      // whole page; tiles would starve it of the codec's threads.
      if (_nativePreviewLoading && overview == null) return;
      while (_nativeLoads < _maxNativeLoads && _readWorker() != null) {
        final key = _nextQueued();
        if (key == null) break;
        unawaited(_loadNativeTile(key, info.levels[key.level]));
      }
      return;
    }
    for (final worker in _workers) {
      if (worker.busy || worker.sendPort == null) continue;
      if (_wantedOnFirstWorker && !identical(worker, _workers.first)) break;
      final key = _nextQueued();
      if (key == null) break;
      _dispatchTile(worker, key);
    }
  }

  /// Requests the overview's image content — its padding past the page edge
  /// cropped off, so it lines up with the page when stretched over it —
  /// shrunk to at most [previewMaxDimension] per side.
  void _sendPreview(_LodWorker worker, PyramidSourceInfo info) {
    final overview = info.overviewLevel;
    final width = math.min(
      overview.width,
      (info.base.width / overview.downsampleX).ceil(),
    );
    final height = math.min(
      overview.height,
      (info.base.height / overview.downsampleY).ceil(),
    );
    var reduction = 0;
    while (math.max(
          reducedExtent(width, reduction),
          reducedExtent(height, reduction),
        ) >
        previewMaxDimension) {
      reduction++;
    }
    _send(
      worker,
      _LodRequest(null, reduction, _version),
      rung: overviewRung,
      width: width,
      height: height,
      memberWidth: overview.width,
      memberHeight: overview.height,
    );
  }

  TileKey? _nextQueued() {
    while (_queueHead < _queue.length) {
      final key = _queue[_queueHead++];
      if (_wanted.contains(key) && _needsFetch(key, _wantedReduction)) {
        return key;
      }
    }
    _queue = [];
    _queueHead = 0;
    return null;
  }

  void _dispatchTile(_LodWorker worker, TileKey key) {
    final level = _info!.levels[key.level];
    final x = (key.tileX << key.span) * level.tileWidth;
    final y = (key.tileY << key.span) * level.tileHeight;
    final width = math.min(level.width, x + (level.tileWidth << key.span)) - x;
    final height =
        math.min(level.height, y + (level.tileHeight << key.span)) - y;
    final request = _LodRequest(key, _wantedReduction, _version);
    _inFlight[key] = request;
    final fromOverview = level.rung == overviewRung;
    _send(
      worker,
      request,
      rung: level.rung,
      x: x,
      y: y,
      width: width,
      height: height,
      // A strip band can't be partially decoded, so a composite's columns
      // are decoded together, one band row at a time; the in-memory overview
      // is cut in one piece.
      memberWidth: level.stripBands || fromOverview ? width : level.tileWidth,
      memberHeight: fromOverview ? height : level.tileHeight,
    );
  }

  void _send(
    _LodWorker worker,
    _LodRequest request, {
    required int rung,
    int x = 0,
    int y = 0,
    required int width,
    required int height,
    required int memberWidth,
    required int memberHeight,
  }) {
    final id = _nextRequestId++;
    _requests[id] = request;
    worker.busy = true;
    final LodWorkerRequest message = (
      id: id,
      rung: rung,
      x: x,
      y: y,
      width: width,
      height: height,
      memberWidth: memberWidth,
      memberHeight: memberHeight,
      reduction: request.reduction,
      brightness: _brightness,
      contrast: _contrast,
      gamma: _gamma,
    );
    worker.sendPort!.send(message);
  }

  void _onMessage(_LodWorker worker, Object? message) {
    if (_disposed) {
      // A worker that finished starting after dispose: shut it down.
      if (message is SendPort) message.send(null);
      worker.receivePort?.close();
      return;
    }
    if (message is SendPort) {
      worker.sendPort = message;
      _pump();
    } else if (message is String) {
      worker.receivePort?.close();
      _fail(message);
    } else if (message is (int, Uint8List, int, int)) {
      final (id, rgba, width, height) = message;
      unawaited(_onResult(worker, id, rgba, width, height));
    } else if (message is (int, List<Uint8List?>)) {
      final read = _jpegReads.remove(message.$1);
      if (read != null) {
        worker.pendingReads--;
        read.complete(message.$2);
      }
    } else if (message is (int, String)) {
      final read = _jpegReads.remove(message.$1);
      if (read != null) {
        worker.pendingReads--;
        read.completeError(StateError(message.$2));
      } else {
        _onFailure(worker, message.$1);
      }
    }
  }

  /// The started worker with the fewest tile reads outstanding, preferring
  /// one that isn't busy decoding — reads are quick, so any worker can take
  /// them between its own jobs.
  _LodWorker? _readWorker() {
    _LodWorker? best;
    for (final worker in _workers) {
      if (worker.sendPort == null) continue;
      if (best == null ||
          (best.busy && !worker.busy) ||
          (best.busy == worker.busy &&
              worker.pendingReads < best.pendingReads)) {
        best = worker;
      }
    }
    return best;
  }

  /// [tiles] of [rung] as standalone JPEG streams, read by whichever worker
  /// [_readWorker] picks.
  Future<List<Uint8List?>> _readJpegs(int rung, List<(int, int)> tiles) {
    final worker = _readWorker();
    if (worker == null) {
      return Future.error(StateError('No worker has started'));
    }
    final id = _nextRequestId++;
    final completer = Completer<List<Uint8List?>>();
    _jpegReads[id] = completer;
    worker.pendingReads++;
    final LodJpegRequest message = (id: id, rung: rung, tiles: tiles);
    worker.sendPort!.send(message);
    return completer.future;
  }

  /// Decodes [jpeg] with the platform codec at `1 / 2^reduction` scale, or
  /// null if there's nothing decodable.
  static Future<ui.Image?> _decodeJpeg(Uint8List? jpeg, int reduction) async {
    if (jpeg == null) return null;
    try {
      // Disposed by the codec call once the codec holds the bytes.
      final buffer = await ui.ImmutableBuffer.fromUint8List(jpeg);
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) => reduction == 0
            ? const ui.TargetImageSize()
            : ui.TargetImageSize(
                width: reducedExtent(width, reduction),
                height: reducedExtent(height, reduction),
              ),
      );
      try {
        return (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return null;
    }
  }

  /// [image] with the current adjustments baked in — natively decoded
  /// pixels never pass through a worker, so they're adjusted here.
  Future<ui.Image> _adjusted(ui.Image image) async {
    final (brightness, contrast, gamma) = (_brightness, _contrast, _gamma);
    if (brightness == 0 && contrast == 1 && gamma == 1) return image;
    final width = image.width;
    final height = image.height;
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    final rgba = ImageAdjustments.apply(
      data!.buffer.asUint8List(),
      brightness: brightness,
      contrast: contrast,
      gamma: gamma,
    );
    return _decodeImage(rgba, width, height);
  }

  bool _isCurrent(TileKey key, _LodRequest request) =>
      !_disposed && request.version == _version && _wanted.contains(key);

  /// Loads [key] of a [LodLevel.nativeJpeg] level.
  Future<void> _loadNativeTile(TileKey key, LodLevel level) async {
    final request = _LodRequest(key, _wantedReduction, _version);
    _inFlight[key] = request;
    _nativeLoads++;
    ui.Image? image;
    var abandoned = false;
    try {
      (image, abandoned) = await _assembleNative(key, request, level);
      if (image != null && !_disposed && request.version == _version) {
        image = await _adjusted(image);
      }
    } catch (_) {
      image?.dispose();
      image = null;
    } finally {
      _nativeLoads--;
      if (identical(_inFlight[key], request)) _inFlight.remove(key);
    }
    if (_disposed || request.version != _version) {
      image?.dispose();
    } else if (image != null) {
      _store(key, request, image);
    } else if (!abandoned) {
      // Nothing in it could be decoded — don't keep asking.
      if (_failed.length >= _maxFailedMemo) _failed.clear();
      _failed.add(key);
    }
    _pump();
    if (!_disposed) notifyListeners();
  }

  /// [key]'s tile, or its composite: members decoded at up to 1/8 scale and
  /// drawn in row by row, so only one row of decoded members is ever held
  /// at once. Returns null with `true` if the viewport stopped wanting it
  /// midway, null with `false` if no member could be decoded.
  Future<(ui.Image?, bool)> _assembleNative(
    TileKey key,
    _LodRequest request,
    LodLevel level,
  ) async {
    final reduction = request.reduction;
    final firstTx = key.tileX << key.span;
    final firstTy = key.tileY << key.span;
    if (key.span == 0 && reduction <= _maxNativeReduction) {
      final jpegs = await _readJpegs(level.rung, [(firstTx, firstTy)]);
      if (!_isCurrent(key, request)) return (null, true);
      return (await _decodeJpeg(jpegs.single, reduction), false);
    }

    final grid = LodGrid(level, 0);
    final lastTx = math.min(firstTx + (1 << key.span), grid.tilesAcross) - 1;
    final lastTy = math.min(firstTy + (1 << key.span), grid.tilesDown) - 1;
    final width = reducedExtent(
      math.min(level.width, (lastTx + 1) * level.tileWidth) -
          firstTx * level.tileWidth,
      reduction,
    );
    final height = reducedExtent(
      math.min(level.height, (lastTy + 1) * level.tileHeight) -
          firstTy * level.tileHeight,
      reduction,
    );
    final memberReduction = math.min(reduction, _maxNativeReduction);
    final memberScale = (1 << memberReduction) / (1 << reduction);
    final stepX = level.tileWidth / (1 << reduction);
    final stepY = level.tileHeight / (1 << reduction);

    ui.Image? composite;
    var anyMember = false;
    for (var ty = firstTy; ty <= lastTy; ty++) {
      final jpegs = await _readJpegs(level.rung, [
        for (var tx = firstTx; tx <= lastTx; tx++) (tx, ty),
      ]);
      if (!_isCurrent(key, request)) {
        composite?.dispose();
        return (null, true);
      }
      final members = await Future.wait([
        for (final jpeg in jpegs) _decodeJpeg(jpeg, memberReduction),
      ]);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      if (composite != null) {
        canvas.drawImage(composite, Offset.zero, _imagePaint);
      }
      for (var i = 0; i < members.length; i++) {
        final member = members[i];
        if (member == null) continue;
        anyMember = true;
        canvas.drawImageRect(
          member,
          Rect.fromLTWH(
            0,
            0,
            member.width.toDouble(),
            member.height.toDouble(),
          ),
          Rect.fromLTWH(
            i * stepX,
            (ty - firstTy) * stepY,
            member.width * memberScale,
            member.height * memberScale,
          ),
          _imagePaint,
        );
      }
      final picture = recorder.endRecording();
      final next = await picture.toImage(width, height);
      picture.dispose();
      for (final member in members) {
        member?.dispose();
      }
      composite?.dispose();
      composite = next;
      if (!_isCurrent(key, request)) {
        composite.dispose();
        return (null, true);
      }
    }
    if (!anyMember) {
      composite?.dispose();
      return (null, false);
    }
    return (composite, false);
  }

  /// Tiles sampled per axis for the preview of a page too big to overview.
  static const _nativePreviewSamples = 32;

  /// Pixels per sampled tile in that preview: enough to average each sample
  /// down to its overall color, little enough that the preview — stretched
  /// smoothly over the page — reads as a soft color map, not a mosaic of
  /// out-of-place tile detail.
  static const _nativePreviewCell = 16;

  /// Bilinear without mipmaps: an exact 2:1 draw averages each 2x2 block.
  static final _halvingPaint = Paint()..filterQuality = FilterQuality.low;

  /// A quick preview of a JPEG-tiled page too big for a real overview: an
  /// evenly spaced grid of tiles, decoded natively at 1/8 scale and each
  /// shrunk to a few pixels standing in for its block of the page.
  Future<void> _loadNativePreview(PyramidSourceInfo info) async {
    final version = _version;
    final level = info.levels[info.overview.rung];
    _nativeLoads++;
    _nativePreviewLoading = true;
    ui.Image? image;
    final members = <ui.Image>[];
    try {
      final contentWidth = info.base.width / level.downsampleX;
      final contentHeight = info.base.height / level.downsampleY;
      final tilesAcross = (contentWidth / level.tileWidth).ceil();
      final tilesDown = (contentHeight / level.tileHeight).ceil();
      final columns = math.min(tilesAcross, _nativePreviewSamples);
      final rows = math.min(tilesDown, _nativePreviewSamples);
      final width = columns * _nativePreviewCell;
      final height = rows * _nativePreviewCell;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var row = 0; row < rows; row++) {
        final jpegs = await _readJpegs(level.rung, [
          for (var column = 0; column < columns; column++)
            (column * tilesAcross ~/ columns, row * tilesDown ~/ rows),
        ]);
        if (_disposed || version != _version) return;
        final decoded = await Future.wait([
          for (final jpeg in jpegs) _decodeJpeg(jpeg, _maxNativeReduction),
        ]);
        for (var column = 0; column < columns; column++) {
          final member = decoded[column];
          if (member == null) continue;
          members.add(member);
          canvas.drawImageRect(
            member,
            Rect.fromLTWH(
              0,
              0,
              member.width.toDouble(),
              member.height.toDouble(),
            ),
            Rect.fromLTWH(
              (column * _nativePreviewCell).toDouble(),
              (row * _nativePreviewCell).toDouble(),
              _nativePreviewCell.toDouble(),
              _nativePreviewCell.toDouble(),
            ),
            _imagePaint,
          );
        }
      }
      final picture = recorder.endRecording();
      var staged = await picture.toImage(width, height);
      picture.dispose();
      for (final member in members) {
        member.dispose();
      }
      members.clear();
      // Halve down to one pixel per sample — its average color — so the
      // preview, stretched smoothly over the page, is a soft color map
      // rather than a mosaic of out-of-place tile detail.
      for (var cell = _nativePreviewCell; cell > 1; cell ~/= 2) {
        final halfWidth = columns * cell ~/ 2;
        final halfHeight = rows * cell ~/ 2;
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawImageRect(
          staged,
          Rect.fromLTWH(
            0,
            0,
            staged.width.toDouble(),
            staged.height.toDouble(),
          ),
          Rect.fromLTWH(0, 0, halfWidth.toDouble(), halfHeight.toDouble()),
          _halvingPaint,
        );
        final halving = recorder.endRecording();
        final next = await halving.toImage(halfWidth, halfHeight);
        halving.dispose();
        staged.dispose();
        staged = next;
      }
      image = await _adjusted(staged);
    } catch (_) {
      image?.dispose();
      image = null;
    } finally {
      for (final member in members) {
        member.dispose();
      }
      _nativeLoads--;
      _nativePreviewLoading = false;
    }
    if (_disposed || version != _version) {
      image?.dispose();
    } else if (image == null) {
      _overviewFailed = true;
      _refresh();
    } else {
      overview?.dispose();
      overview = image;
      _overviewVersion = version;
      _markMinimapDirty();
    }
    _pump();
    if (!_disposed) notifyListeners();
  }

  _LodRequest? _finish(_LodWorker worker, int id) {
    worker.busy = false;
    final request = _requests.remove(id);
    final key = request?.key;
    if (key != null && identical(_inFlight[key], request)) {
      _inFlight.remove(key);
    }
    return request;
  }

  Future<void> _onResult(
    _LodWorker worker,
    int id,
    Uint8List rgba,
    int width,
    int height,
  ) async {
    final request = _finish(worker, id);
    // Give the now-idle worker its next job before the GPU upload below.
    _pump();
    if (request == null || request.version != _version) {
      notifyListeners();
      return;
    }
    final image = await _decodeImage(rgba, width, height);
    if (_disposed || request.version != _version) {
      image.dispose();
      return;
    }
    final key = request.key;
    if (key == null) {
      overview?.dispose();
      overview = image;
      _overviewVersion = request.version;
      _markMinimapDirty();
    } else {
      _store(key, request, image);
    }
    notifyListeners();
  }

  void _onFailure(_LodWorker worker, int id) {
    final request = _finish(worker, id);
    if (request != null && request.version == _version) {
      final key = request.key;
      if (key == null) {
        // The overview can't be decoded: drop its level, so zoomed-out views
        // are loaded from the page's own rungs instead.
        _overviewFailed = true;
        _refresh();
      } else {
        if (_failed.length >= _maxFailedMemo) _failed.clear();
        _failed.add(key);
      }
    }
    _pump();
    notifyListeners();
  }

  void _store(TileKey key, _LodRequest request, ui.Image image) {
    final byteSize = image.width * image.height * 4;
    final wanted = _wanted.contains(key);
    final cached = _cache.peek(key);
    // A result the viewport stopped wanting is only kept if it fits without
    // evicting anything — it must never push out tiles still on screen. Nor
    // may a blurrier result replace a sharper copy of the same pixels.
    if ((!wanted && _cache.currentBytes + byteSize > _cache.maxBytes) ||
        (cached != null &&
            cached.version == request.version &&
            cached.reduction < request.reduction)) {
      image.dispose();
      return;
    }
    _cache.put(
      key,
      image,
      byteSize,
      reduction: request.reduction,
      version: request.version,
    );
    _markMinimapDirty();
    if (wanted && request.reduction > _wantedReduction) {
      // Landed blurrier than the viewport now needs (it zoomed in while this
      // was in flight) — keep it on screen, but fetch a sharper one.
      _queue.add(key);
      _pump();
    }
  }

  static Future<ui.Image> _decodeImage(Uint8List rgba, int width, int height) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  // Anti-aliased edges on abutting tiles each blend against what was already
  // painted, leaving hairline seams even when the edges coincide; without
  // anti-aliasing each edge snaps to whole device pixels instead.
  static final _imagePaint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = false;

  /// Floating-point drift can leave neighboring tiles' edges a fraction of a
  /// pixel apart; overlapping each tile 1px into the next hides that.
  static const _seamGuard = 1.0;

  /// Paints the page into a [size] viewport at [scale] screen pixels per base
  /// pixel, with base point [origin] at the top-left corner.
  void paint(Canvas canvas, Size size, double scale, Offset origin) {
    final info = _info;
    if (info == null) return;
    final extent = Rect.fromLTWH(
      -origin.dx * scale,
      -origin.dy * scale,
      info.base.width * scale,
      info.base.height * scale,
    );
    final target = _targetLevelFor(info, scale);
    final level = info.levels[target];
    final grid = LodGrid(level, _planFor(level, scale).$1);
    final visible = grid.visible(size, scale, origin);
    if (visible == null) return;

    // Until every visible tile of the target rung is in, paint what's already
    // at hand underneath — the preview, then every cached rung from coarsest
    // to sharpest — so a zoom sharpens progressively instead of reloading. Skipped once
    // complete: it would be painted over anyway, and leaving those tiles
    // untouched lets the cache age them out.
    if (_cache.countInRange(target, grid.span, visible) < visible.count) {
      _paintStretched(canvas, overview, extent);
      for (final (layerLevel, layerGrid, layerRange) in _fallbackLayers(
        info,
        target,
        grid.span,
        size,
        scale,
        origin,
      )) {
        _paintTiles(canvas, extent, layerLevel, layerGrid, layerRange, scale);
      }
    }
    _paintTiles(canvas, extent, target, grid, visible, scale);
  }

  void _paintStretched(Canvas canvas, ui.Image? image, Rect extent) {
    if (image == null) return;
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    canvas.drawImageRect(image, src, extent, _imagePaint);
  }

  /// Every cached (level, span) group besides the target with tiles in view,
  /// coarsest first — so each sharper layer paints over a blurrier one, and
  /// a zoom sharpens step by step from whatever is at hand. Painting only
  /// the nearest group would drop to the preview wherever that group happens
  /// not to reach (typically the edges of the previous viewport), which
  /// reads as the whole view reloading.
  List<(int, LodGrid, TileRange)> _fallbackLayers(
    PyramidSourceInfo info,
    int targetLevel,
    int targetSpan,
    Size size,
    double scale,
    Offset origin,
  ) {
    final layers = <(int, LodGrid, TileRange)>[];
    for (final (levelIndex, span) in _cache.cachedGroups) {
      if (levelIndex == targetLevel && span == targetSpan) continue;
      final grid = LodGrid(info.levels[levelIndex], span);
      final range = grid.visible(size, scale, origin);
      if (range != null && _cache.countInRange(levelIndex, span, range) > 0) {
        layers.add((levelIndex, grid, range));
      }
    }
    // Composites of the same level are usually delivered more reduced the
    // bigger their span, so they count as coarser too.
    layers.sort((a, b) {
      final byDownsample = b.$2.level.downsampleX.compareTo(
        a.$2.level.downsampleX,
      );
      return byDownsample != 0 ? byDownsample : b.$2.span.compareTo(a.$2.span);
    });
    return layers;
  }

  void _paintTiles(
    Canvas canvas,
    Rect extent,
    int levelIndex,
    LodGrid grid,
    TileRange range,
    double scale,
  ) {
    final level = grid.level;
    // A composite or edge tile can overhang the page by under a pixel after
    // rounding its reduced size up; the clip hides that.
    canvas.save();
    canvas.clipRect(extent);
    _cache.forEachInRange(levelIndex, grid.span, range, (key, tile) {
      _drawTile(
        canvas,
        _tileRect(extent, level, grid, key, tile, scale),
        tile.image,
        _seamGuard,
      );
    });
    canvas.restore();
  }

  /// Where [tile] (keyed [key] in [grid]) lands with the page drawn into
  /// [extent] at [scale].
  static Rect _tileRect(
    Rect extent,
    LodLevel level,
    LodGrid grid,
    TileKey key,
    CachedTile tile,
    double scale,
  ) {
    final texels = (1 << tile.reduction).toDouble();
    return Rect.fromLTWH(
      extent.left + key.tileX * grid.tileWidth * level.downsampleX * scale,
      extent.top + key.tileY * grid.tileHeight * level.downsampleY * scale,
      tile.image.width * texels * level.downsampleX * scale,
      tile.image.height * texels * level.downsampleY * scale,
    );
  }

  static void _drawTile(
    Canvas canvas,
    Rect dst,
    ui.Image image,
    double seamGuard,
  ) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
        dst.left,
        dst.top,
        dst.width + seamGuard,
        dst.height + seamGuard,
      ),
      _imagePaint,
    );
  }

  /// The level [paint] shows at [scale], for display: its index among the
  /// source's levels (0 is the page at full resolution, coarser ones follow)
  /// and how many page pixels one of its pixels spans per side.
  (int, double)? levelAt(double scale) {
    final info = _info;
    if (info == null) return null;
    final index = _targetLevelFor(info, scale);
    return (index, info.levels[index].downsampleX);
  }

  /// Longest side, in pixels, of [minimapImage].
  static const minimapMaxDimension = 512;

  /// How often [minimapImage] is redrawn at most while tiles keep arriving.
  static const _minimapInterval = Duration(milliseconds: 400);

  /// Tiles that would land smaller than this per side add nothing a minimap
  /// can show — and a zoomed-in cache holds hundreds of them.
  static const _minimapMinTileExtent = 2.0;

  ui.Image? _minimap;
  int _minimapVersion = -1;
  bool _minimapDirty = false;
  bool _minimapRendering = false;
  Timer? _minimapTimer;

  /// A thumbnail of the whole page for a minimap: the preview with every
  /// tile loaded so far drawn over it, sharpest on top, over what earlier
  /// thumbnails picked up from tiles since evicted — so the minimap sharpens
  /// as the page is explored rather than staying at the preview's quality.
  /// Redrawn at most every 400ms while tiles arrive; [overview] until the
  /// first one is ready.
  ui.Image? get minimapImage => _minimap ?? overview;

  void _markMinimapDirty() {
    _minimapDirty = true;
    _scheduleMinimap();
  }

  void _scheduleMinimap() {
    if (_disposed ||
        !_minimapDirty ||
        _minimapRendering ||
        _minimapTimer != null) {
      return;
    }
    _minimapTimer = Timer(_minimapInterval, () {
      _minimapTimer = null;
      unawaited(_renderMinimap());
    });
  }

  Future<void> _renderMinimap() async {
    final info = _info;
    if (_disposed || info == null) return;
    final version = _version;
    final preview = overview;
    // Wait for the re-adjusted preview (whose arrival reschedules this)
    // rather than lay new adjustments over old ones.
    if (preview != null && _overviewVersion != version && !_overviewFailed) {
      return;
    }
    _minimapDirty = false;
    _minimapRendering = true;
    ui.Image? image;
    try {
      final base = info.base;
      final scale = math.min(
        1.0,
        minimapMaxDimension / math.max(base.width, base.height),
      );
      final extent = Rect.fromLTWH(
        0,
        0,
        base.width * scale,
        base.height * scale,
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..clipRect(extent);
      if (_overviewVersion == version) {
        _paintStretched(canvas, preview, extent);
      }
      if (_minimapVersion == version) {
        _paintStretched(canvas, _minimap, extent);
      }
      double texelSize((TileKey, CachedTile) entry) =>
          info.levels[entry.$1.level].downsampleX * (1 << entry.$2.reduction);
      final tiles = [
        for (final MapEntry(:key, :value) in _cache.entries)
          if (value.version == version) (key, value),
      ]..sort((a, b) => texelSize(b).compareTo(texelSize(a)));
      for (final (key, tile) in tiles) {
        final level = info.levels[key.level];
        final dst = _tileRect(
          extent,
          level,
          LodGrid(level, key.span),
          key,
          tile,
          scale,
        );
        if (dst.width < _minimapMinTileExtent &&
            dst.height < _minimapMinTileExtent) {
          continue;
        }
        _drawTile(canvas, dst, tile.image, 0.5);
      }
      final picture = recorder.endRecording();
      try {
        image = await picture.toImage(
          extent.width.ceil(),
          extent.height.ceil(),
        );
      } finally {
        picture.dispose();
      }
    } catch (_) {
      image?.dispose();
      image = null;
    } finally {
      _minimapRendering = false;
    }
    if (_disposed) {
      image?.dispose();
      return;
    }
    if (version != _version) {
      image?.dispose();
      _minimapDirty = true;
    } else if (image != null) {
      _minimap?.dispose();
      _minimap = image;
      _minimapVersion = version;
      notifyListeners();
    }
    _scheduleMinimap();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _minimapTimer?.cancel();
    _minimap?.dispose();
    _minimap = null;
    for (final read in _jpegReads.values) {
      read.completeError(StateError('LodEngine disposed'));
    }
    _jpegReads.clear();
    for (final worker in _workers) {
      final sendPort = worker.sendPort;
      if (sendPort != null) {
        sendPort.send(null);
        worker.receivePort?.close();
      }
      // Otherwise the port stays open to catch the worker's handshake, and
      // _onMessage shuts that worker down as soon as it arrives.
    }
    overview?.dispose();
    overview = null;
    _cache.clear();
    super.dispose();
  }
}
