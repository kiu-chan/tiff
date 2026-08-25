import 'dart:math' as math;
import 'dart:typed_data';

import '../../tiff_exception.dart';

/// Brightness/contrast/gamma adjustment for already-decoded 8-bit RGBA
/// pixel data (e.g. the output of [TiffImage.decodeRgba8]).
///
/// All three adjustments are combined into a single 256-entry lookup table
/// and applied identically to the R, G, and B channels; the alpha channel is
/// left untouched. Defaults (`brightness: 0, contrast: 1, gamma: 1`) are a
/// no-op — [apply] returns the input unchanged in that case, without
/// allocating a new buffer.
class ImageAdjustments {
  const ImageAdjustments._();

  /// Applies brightness/contrast/gamma to interleaved 8-bit RGBA data
  /// ([rgba]'s length must be a multiple of 4), returning a new buffer.
  ///
  /// - [brightness]: additive offset in sample units, applied last. Positive
  ///   values lighten, negative values darken. Not clamped to a fixed range;
  ///   the result is clamped to `[0, 255]` per channel regardless.
  /// - [contrast]: multiplicative factor around the mid-gray point (127.5),
  ///   applied after gamma. `1.0` (the default) is a no-op; `>1` increases
  ///   contrast, `<1` (down to `0`) decreases it.
  /// - [gamma]: power-law exponent applied first, as `out = in ^ (1/gamma)`
  ///   on the normalized `[0,1]` sample value. `1.0` (the default) is a
  ///   no-op; `>1` brightens midtones, `<1` darkens them. Must be `> 0`.
  static Uint8List apply(
    Uint8List rgba, {
    double brightness = 0,
    double contrast = 1,
    double gamma = 1,
  }) {
    if (rgba.length % 4 != 0) {
      throw const TiffException(
        'ImageAdjustments.apply expects interleaved RGBA8 data (length must be a multiple of 4)',
      );
    }
    if (gamma <= 0) {
      throw TiffException('gamma must be greater than 0, got $gamma');
    }
    if (brightness == 0 && contrast == 1 && gamma == 1) {
      return rgba;
    }

    final lut = _buildLut(brightness: brightness, contrast: contrast, gamma: gamma);
    final out = Uint8List(rgba.length);
    for (var i = 0; i < rgba.length; i += 4) {
      out[i] = lut[rgba[i]];
      out[i + 1] = lut[rgba[i + 1]];
      out[i + 2] = lut[rgba[i + 2]];
      out[i + 3] = rgba[i + 3];
    }
    return out;
  }

  static Uint8List _buildLut({
    required double brightness,
    required double contrast,
    required double gamma,
  }) {
    final invGamma = 1 / gamma;
    return Uint8List.fromList([
      for (var v = 0; v < 256; v++)
        _adjustSample(v, brightness: brightness, contrast: contrast, invGamma: invGamma),
    ]);
  }

  static int _adjustSample(
    int value, {
    required double brightness,
    required double contrast,
    required double invGamma,
  }) {
    var v = math.pow(value / 255.0, invGamma).toDouble() * 255.0;
    v = (v - 127.5) * contrast + 127.5;
    v = v + brightness;
    return v.round().clamp(0, 255);
  }
}
