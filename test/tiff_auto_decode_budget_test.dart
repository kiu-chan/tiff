import 'dart:io';

import 'package:test/test.dart';
import 'package:tiff/tiff.dart';
import 'package:tiff/tiff_io.dart';

TiffImageMetadata _tiledMetadata({
  required int width,
  required int height,
  required int tileWidth,
  required int tileLength,
  int samplesPerPixel = 3,
}) => TiffImageMetadata(
  width: width,
  height: height,
  bitsPerSample: List.filled(samplesPerPixel, 8),
  samplesPerPixel: samplesPerPixel,
  compression: 1,
  predictor: 1,
  photometric: TiffPhotometric.rgb,
  planarConfiguration: TiffPlanarConfiguration.chunky,
  rowsPerStrip: height,
  stripOffsets: const [],
  stripByteCounts: const [],
  tileWidth: tileWidth,
  tileLength: tileLength,
  tileOffsets: const [0],
  tileByteCounts: const [0],
  colorMap: null,
  geoTiff: null,
  exifTags: null,
  gpsTags: null,
  rawTags: const {},
);

void main() {
  group('SystemMemoryInfo.probe', () {
    test('never throws, and returns internally-consistent numbers when supported', () {
      final mem = SystemMemoryInfo.probe();
      if (mem == null) return; // Unsupported here (e.g. CI sandbox) — nothing to assert.
      expect(mem.totalBytes, greaterThan(0));
      expect(mem.availableBytes, greaterThanOrEqualTo(0));
      expect(mem.availableBytes, lessThanOrEqualTo(mem.totalBytes));
    });

    test('reuses a cached reading within maxAge', () {
      final first = SystemMemoryInfo.probe();
      final second = SystemMemoryInfo.probe(maxAge: const Duration(minutes: 5));
      expect(second, same(first));
    });
  });

  group('TiffAutoDecodeBudget.recommend', () {
    test('falls back to fallbackAggregateBytes when told to ignore the system reading', () {
      final metadata = _tiledMetadata(width: 4096, height: 4096, tileWidth: 512, tileLength: 512);
      // A fraction of 0 means "use none of whatever's available", so the
      // result should bottom out at minAggregateBytes regardless of this
      // machine's actual memory.
      // reservedCores forced absurdly high so cpuCount bottoms out at 1 —
      // isolating this assertion from the separate per-core division
      // covered below.
      final budget = TiffAutoDecodeBudget.recommend(
        metadata,
        systemMemoryFraction: 0,
        minAggregateBytes: 32 * 1024 * 1024,
        reservedCores: 1 << 20,
      );
      expect(budget.maxBytesPerChunk, 32 * 1024 * 1024);
      expect(budget.workerCount, greaterThanOrEqualTo(1));
    });

    test('never recommends zero workers for a huge whole-slide-image-shaped page', () {
      // Wide enough that one native-tile-row-aligned chunk costs well over
      // 1GB — this used to be exactly the shape that could drive a naive
      // fixed budget down to a degenerate plan.
      final metadata = _tiledMetadata(width: 131072, height: 100352, tileWidth: 512, tileLength: 512);
      final budget = TiffAutoDecodeBudget.recommend(metadata);
      expect(budget.workerCount, greaterThanOrEqualTo(1));
      expect(budget.maxBytesPerChunk, greaterThan(0));
    });

    test('uses every idle core for a huge page even when the budget is too small for one full-tile-row chunk per core', () {
      // Same whole-slide-image shape as above (one native tile-row chunk
      // costs ~1.75GB), but with a budget that can't afford even a handful
      // of those — this is exactly the case that used to collapse to a
      // single worker (and idle every other core) regardless of how many
      // cores were free, because the whole budget went to sizing one chunk
      // instead of being split across chunks first.
      final metadata = _tiledMetadata(width: 131072, height: 100352, tileWidth: 512, tileLength: 512);
      final budget = TiffAutoDecodeBudget.recommend(
        metadata,
        systemMemoryFraction: 0,
        fallbackAggregateBytes: 512 * 1024 * 1024,
        reservedCores: 0,
      );
      final cpuCount = Platform.numberOfProcessors;
      expect(budget.workerCount, cpuCount > 1 ? greaterThan(1) : 1);
    });

    test('scales worker count up for a small page given a generous budget', () {
      final metadata = _tiledMetadata(width: 512, height: 512, tileWidth: 512, tileLength: 512);
      final budget = TiffAutoDecodeBudget.recommend(
        metadata,
        systemMemoryFraction: 0, // force the fallback path, deterministic regardless of host machine
        fallbackAggregateBytes: 256 * 1024 * 1024,
        reservedCores: 0,
      );
      // One 512x512x3-channel tile-row chunk costs a few MB raw — orders of
      // magnitude under the 256MB budget, so this should recommend as many
      // workers as cores allow, not fall back to 1 — unless this machine
      // only has one core to begin with.
      expect(budget.workerCount, Platform.numberOfProcessors > 1 ? greaterThan(1) : 1);
    });
  });
}
