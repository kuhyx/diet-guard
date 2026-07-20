/// Platform entry point for rendering an attached meal photo.
///
/// Conditional export because the two platforms resolve a photo differently:
/// Android has a real file at the stored path, while the browser-hosted
/// desktop app has to read the bytes back out of IndexedDB before it can show
/// anything (`Image.file` is a `dart:io` stub there and would throw).
library;

export 'attached_image_io.dart'
    if (dart.library.js_interop) 'attached_image_web.dart';
