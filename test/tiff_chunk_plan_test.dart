import 'package:test/test.dart';
import 'package:tiff/tiff.dart';

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

TiffImageMetadata _stripMetadata({
  required int width,
  required int height,
  required int rowsPerStrip,
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
  rowsPerStrip: rowsPerStrip,
  stripOffsets: const [0],
  stripByteCounts: const [0],
  tileWidth: null,
  tileLength: null,
  tileOffsets: null,
  tileByteCounts: null,
  colorMap: null,
  geoTiff: null,
  exifTags: null,
  gpsTags: null,
  rawTags: const {},
);

void main() {
  group('TiffChunkPlan.forBudget', () {
    test('a generous budget produces one chunk per tile row (no shrinking below tile height)', () {
      final metadata = _tiledMetadata(width: 1000, height: 2048, tileWidth: 512, tileLength: 512);
      final plan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: 100 * 1024 * 1024);

      expect(plan.chunkHeight, 512);
      expect(plan.chunks, [(0, 512), (512, 512), (1024, 512), (1536, 512)]);
      // samplesPerPixel(3)*8+4 = 28 bytes/pixel; 1000 wide * 512 tall * 28.
      expect(plan.bytesPerChunk, 1000 * 512 * 28);
    });

    test('a tight budget shrinks chunks below tile height rather than exceeding it', () {
      final metadata = _tiledMetadata(width: 10000, height: 2048, tileWidth: 512, tileLength: 512);
      // One row at this width already costs 10000 * (3*8+4) = 280000 bytes —
      // a budget below one full tile row (512 * 280000) forces shrinking.
      final plan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: 2 * 1024 * 1024);

      expect(plan.chunkHeight, lessThan(512));
      expect(plan.chunkHeight, greaterThan(0));
      // Every chunk boundary still tiles the page exactly, just in smaller pieces.
      expect(plan.chunks.first.$1, 0);
      expect(plan.chunks.last.$1 + plan.chunks.last.$2, 2048);
    });

    test('never shrinks below minChunkHeight even for an absurdly small budget', () {
      final metadata = _tiledMetadata(width: 100000, height: 16, tileWidth: 512, tileLength: 512);
      final plan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: 1, minChunkHeight: 3);

      expect(plan.chunkHeight, 3);
    });

    test('a page shorter than the natural chunk height produces exactly one chunk', () {
      final metadata = _tiledMetadata(width: 100, height: 50, tileWidth: 512, tileLength: 512);
      final plan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: 100 * 1024 * 1024);

      expect(plan.chunks, [(0, 50)]);
    });

    test('the last chunk is shorter when height is not a multiple of chunkHeight', () {
      final metadata = _tiledMetadata(width: 100, height: 1000, tileWidth: 300, tileLength: 300);
      final plan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: 100 * 1024 * 1024);

      expect(plan.chunkHeight, 300);
      expect(plan.chunks, [(0, 300), (300, 300), (600, 300), (900, 100)]);
    });

    test('a strip-organized page uses rowsPerStrip as the natural chunk height', () {
      final metadata = _stripMetadata(width: 100, height: 400, rowsPerStrip: 100);
      final plan = TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: 100 * 1024 * 1024);

      expect(plan.chunkHeight, 100);
    });

    test('rejects a non-positive budget or minChunkHeight', () {
      final metadata = _tiledMetadata(width: 100, height: 100, tileWidth: 50, tileLength: 50);
      expect(() => TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: 0), throwsArgumentError);
      expect(() => TiffChunkPlan.forBudget(metadata, maxBytesPerChunk: 100, minChunkHeight: 0), throwsArgumentError);
    });
  });

  group('TiffChunkPlan.recommendedWorkerCount', () {
    test('divides the aggregate budget by the chunk size', () {
      final count = TiffChunkPlan.recommendedWorkerCount(
        bytesPerChunk: 50 * 1024 * 1024,
        aggregateBudgetBytes: 200 * 1024 * 1024,
        cpuCount: 8,
      );
      expect(count, 4);
    });

    test('is capped by cpuCount even when memory would allow more', () {
      final count = TiffChunkPlan.recommendedWorkerCount(
        bytesPerChunk: 1 * 1024 * 1024,
        aggregateBudgetBytes: 1000 * 1024 * 1024,
        cpuCount: 3,
      );
      expect(count, 3);
    });

    test('falls back to 1 rather than 0 when one chunk alone exceeds the budget', () {
      final count = TiffChunkPlan.recommendedWorkerCount(
        bytesPerChunk: 500 * 1024 * 1024,
        aggregateBudgetBytes: 100 * 1024 * 1024,
        cpuCount: 8,
      );
      expect(count, 1);
    });
  });
}
