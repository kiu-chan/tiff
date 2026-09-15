/// Optional Flutter viewer for TIFF/BigTIFF pages of any size.
///
/// Import this, from a Flutter app, for [TiffImageView]: a pannable,
/// zoomable view that decodes only the tiles on screen, on background
/// isolates, at the pyramid rung matching the zoom — so a multi-gigapixel
/// page opens and moves as smoothly as a small one. It reads files through
/// `dart:io`, so it is not available on the web.
library;

export 'src/viewer/tiff_image_view.dart'
    show TiffImageView, TiffImageViewStart, TiffImageViewState;
