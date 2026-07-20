/// Byte-blob persistence for attached meal photos.
library;

import 'dart:typed_data';

/// Stores and retrieves photo bytes under an opaque key.
///
/// The key is what ends up in [FoodEntry.imagePath]: an absolute file path on
/// Android (unchanged from before the web build existed, so installed phones
/// keep resolving their existing photos) and an IndexedDB key in the browser.
/// Callers must treat it as opaque and never join, split or stat it.
///
/// Deliberately free of `dart:io` -- see `document_store.dart` for why that
/// matters for the web build.
abstract class BlobStore {
  /// Stores [bytes] as a new blob whose key ends with [extension] (`.jpg`),
  /// returning the key.
  Future<String> put(String extension, Uint8List bytes);

  /// Returns the bytes stored under [key], or null when it is gone.
  Future<Uint8List?> get(String key);
}
