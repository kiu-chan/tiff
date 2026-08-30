/// Optional Flutter widget entry point.
///
/// `package:tiff` never imports `package:flutter` from its main entry point
/// (`package:tiff/tiff.dart`) or any other library file — those stay usable
/// from plain Dart (a server, a CLI tool, a non-Flutter Dart web app) with no
/// Flutter SDK involved at all. Import *this* library instead, from a
/// Flutter app, for [TiffMinimap] — a ready-made overview-with-viewport-
/// rectangle widget for panning/zooming a large TIFF page. Adding this
/// import (and only this one) opts your dependency on `package:tiff` into
/// requiring the Flutter SDK.
library;

export 'src/widgets/tiff_minimap.dart' show TiffMinimap;
