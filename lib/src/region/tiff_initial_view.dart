import 'dart:math' as math;

import '../image/image_metadata.dart';
import 'tiff_region.dart';

/// A region and display scale to show first for a page, sized for a
/// viewer's viewport instead of the whole page.
///
/// Decoding a full-resolution multi-gigapixel BigTIFF page just to show an
/// initial frame can mean gigabytes of RGBA8 for a single frame that's
/// mostly downsampled away on screen anyway. [TiffInitialView.forViewport]
/// instead picks a region centered on the page, sized to stay within a
/// decode budget, plus the [zoom] to display it at so it fills the
/// viewport — the same idea as [TiffImage.decodeRegion]/
/// [TiffImage.decodeRegionRgba8], applied to picking where to start.
class TiffInitialView {
  /// The region to decode, centered on the page.
  final TiffRegion region;

  /// The scale (device pixels per image pixel) to display [region] at so it
  /// fills the requested viewport. Values above 1 mean [region] is smaller
  /// than the viewport — the decode budget capped it below native
  /// resolution — and it needs to be scaled up to fill the screen.
  final double zoom;

  const TiffInitialView({required this.region, required this.zoom});

  /// Picks a region centered on [metadata]'s page and the zoom to display
  /// it at, for a viewport of [viewportWidth] x [viewportHeight] logical
  /// pixels at [devicePixelRatio].
  ///
  /// [maxDecodedPixels] caps how many pixels this initial view decodes —
  /// pass a smaller budget on memory-constrained devices, a larger one on
  /// desktop/high-memory devices. The default (4,000,000, e.g. a 2000x2000
  /// region) keeps an RGBA8 decode under 16 MB while still giving a sharp
  /// preview on typical phone/tablet/desktop viewports.
  ///
  /// When the page is already smaller than the viewport (in device pixels),
  /// the region is simply the whole page — there's nothing to save by
  /// cropping it further, and [zoom] comes out above 1 to fill the
  /// viewport.
  factory TiffInitialView.forViewport(
    TiffImageMetadata metadata, {
    required double viewportWidth,
    required double viewportHeight,
    double devicePixelRatio = 1.0,
    int maxDecodedPixels = 4000000,
  }) {
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError(
        'viewportWidth and viewportHeight must be > 0 '
        '(got ${viewportWidth}x$viewportHeight)',
      );
    }
    if (devicePixelRatio <= 0) {
      throw ArgumentError('devicePixelRatio must be > 0');
    }
    if (maxDecodedPixels <= 0) {
      throw ArgumentError('maxDecodedPixels must be > 0');
    }

    final targetWidth = viewportWidth * devicePixelRatio;
    final targetHeight = viewportHeight * devicePixelRatio;

    // The region needed to fill the viewport at native (zoom == 1)
    // resolution, clamped to the page itself.
    var regionWidth = math.min(targetWidth, metadata.width.toDouble());
    var regionHeight = math.min(targetHeight, metadata.height.toDouble());

    // If that's still more pixels than the decode budget allows, shrink it
    // (preserving the viewport's aspect ratio) until it fits — the region
    // will then need to be scaled up (zoom > 1) to fill the viewport.
    final pixelCount = regionWidth * regionHeight;
    if (pixelCount > maxDecodedPixels) {
      final shrink = math.sqrt(maxDecodedPixels / pixelCount);
      regionWidth *= shrink;
      regionHeight *= shrink;
    }

    final width = regionWidth.round().clamp(1, metadata.width);
    final height = regionHeight.round().clamp(1, metadata.height);
    final x = ((metadata.width - width) / 2).round().clamp(
      0,
      metadata.width - width,
    );
    final y = ((metadata.height - height) / 2).round().clamp(
      0,
      metadata.height - height,
    );

    final zoom = math.min(targetWidth / width, targetHeight / height);

    return TiffInitialView(
      region: TiffRegion(x: x, y: y, width: width, height: height),
      zoom: zoom,
    );
  }
}
