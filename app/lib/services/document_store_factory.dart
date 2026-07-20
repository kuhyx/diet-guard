/// Platform entry point for opening the document store.
///
/// Conditional export because `dart:io` cannot even be *imported* in a web
/// compile: Android keeps the file-backed store, the browser-hosted desktop
/// app gets IndexedDB.
library;

export 'document_store_io.dart'
    if (dart.library.js_interop) 'document_store_web.dart';
