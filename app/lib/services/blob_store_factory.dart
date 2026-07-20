/// Platform entry point for opening the photo blob store.
library;

export 'blob_store_io.dart' if (dart.library.js_interop) 'blob_store_web.dart';
