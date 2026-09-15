import 'dart:ui' as ui;

import 'viewport_math.dart';

/// One cached tile: tile ([tileX], [tileY]) of rung [level] — or, when
/// [span] is above 0, the composite of that rung's `2^span` x `2^span` tiles
/// starting at tile (`tileX << span`, `tileY << span`).
class TileKey {
  final int level;
  final int tileX;
  final int tileY;
  final int span;

  const TileKey(this.level, this.tileX, this.tileY, this.span);

  @override
  bool operator ==(Object other) =>
      other is TileKey &&
      other.level == level &&
      other.tileX == tileX &&
      other.tileY == tileY &&
      other.span == span;

  @override
  int get hashCode => Object.hash(level, tileX, tileY, span);
}

/// A decoded tile plus what it was decoded for: [reduction] (each pixel
/// covers `2^reduction` of its rung's texels per side) and the adjustment
/// [version] its pixels were produced under.
class CachedTile {
  final ui.Image image;
  final int byteSize;
  final int reduction;
  final int version;

  const CachedTile(this.image, this.byteSize, this.reduction, this.version);
}

/// Decoded tiles bounded by a decoded-byte budget (not a tile count — tile
/// footprints vary with rung, composite span, and reduction), evicted in
/// strict least-recently-used order across every rung. The painter touches
/// every on-screen tile once per frame via [forEachInRange], so tiles on
/// screen are effectively pinned with no separate mechanism.
///
/// Evicted images are disposed: a [ui.Image] holds GPU memory the Dart
/// garbage collector doesn't see.
class TileCache {
  final int maxBytes;

  /// Iterates oldest-touched first: every touch re-inserts at the end.
  final _entries = <TileKey, CachedTile>{};
  final _groupSizes = <(int, int), int>{};
  int _currentBytes = 0;

  TileCache({required this.maxBytes});

  int get currentBytes => _currentBytes;

  /// Every (level, span) pair with at least one tile cached, so a painter
  /// looking for a fallback only probes groups that exist.
  Iterable<(int, int)> get cachedGroups => _groupSizes.keys;

  /// [key]'s entry without touching it, or null if it isn't cached.
  CachedTile? peek(TileKey key) => _entries[key];

  /// Every cached tile, oldest-touched first, without touching any — for
  /// reading the whole cache (e.g. into a minimap) without pinning it.
  Iterable<MapEntry<TileKey, CachedTile>> get entries => _entries.entries;

  void put(
    TileKey key,
    ui.Image image,
    int byteSize, {
    required int reduction,
    required int version,
  }) {
    final existing = _entries.remove(key);
    if (existing != null) _discard(key, existing);

    while (_entries.isNotEmpty && _currentBytes + byteSize > maxBytes) {
      final victim = _entries.keys.first;
      _discard(victim, _entries.remove(victim)!);
    }

    _entries[key] = CachedTile(image, byteSize, reduction, version);
    _currentBytes += byteSize;
    final group = (key.level, key.span);
    _groupSizes[group] = (_groupSizes[group] ?? 0) + 1;
  }

  void _discard(TileKey key, CachedTile entry) {
    _currentBytes -= entry.byteSize;
    entry.image.dispose();
    final group = (key.level, key.span);
    final remaining = _groupSizes[group]! - 1;
    if (remaining == 0) {
      _groupSizes.remove(group);
    } else {
      _groupSizes[group] = remaining;
    }
  }

  /// How many of [range]'s tiles of ([level], [span]) are cached. Doesn't
  /// touch them.
  int countInRange(int level, int span, TileRange range) {
    var count = 0;
    _visitRange(level, span, range, (_, _) => count++);
    return count;
  }

  /// Calls [visit] with every cached tile of ([level], [span]) in [range],
  /// touching each as most-recently-used.
  void forEachInRange(
    int level,
    int span,
    TileRange range,
    void Function(TileKey key, CachedTile tile) visit,
  ) {
    final hits = <(TileKey, CachedTile)>[];
    _visitRange(level, span, range, (key, entry) => hits.add((key, entry)));
    for (final (key, entry) in hits) {
      _entries.remove(key);
      _entries[key] = entry;
      visit(key, entry);
    }
  }

  /// Walks whichever is smaller: [range]'s grid, or the cache's own entries.
  /// A zoomed-out view can span tens of thousands of a fine rung's tiles
  /// while the cache holds a few hundred — probing every grid cell on every
  /// frame would stall the UI for nothing.
  void _visitRange(
    int level,
    int span,
    TileRange range,
    void Function(TileKey key, CachedTile entry) visit,
  ) {
    if (!_groupSizes.containsKey((level, span))) return;
    if (range.count <= _entries.length) {
      for (var ty = range.minTy; ty <= range.maxTy; ty++) {
        for (var tx = range.minTx; tx <= range.maxTx; tx++) {
          final key = TileKey(level, tx, ty, span);
          final entry = _entries[key];
          if (entry != null) visit(key, entry);
        }
      }
    } else {
      for (final MapEntry(:key, :value) in _entries.entries) {
        if (key.level == level &&
            key.span == span &&
            range.contains(key.tileX, key.tileY)) {
          visit(key, value);
        }
      }
    }
  }

  /// Disposes every cached image — also the response to an OS
  /// memory-pressure signal.
  void clear() {
    for (final entry in _entries.values) {
      entry.image.dispose();
    }
    _entries.clear();
    _groupSizes.clear();
    _currentBytes = 0;
  }
}
