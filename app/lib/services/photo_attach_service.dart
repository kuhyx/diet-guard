/// Picks a photo and copies it into permanent app-local storage.
library;

import 'package:diet_guard_app/services/blob_store.dart';
import 'package:diet_guard_app/services/blob_store_factory.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

/// Wraps [ImagePicker] and persists the result in a [BlobStore], so the
/// returned key survives after the picker's own (possibly cache-cleared)
/// temp file is gone.
///
/// Photos are device-local only: per the sync plan (Milestone 3), a logged
/// entry's `imagePath` is stripped before push and never read from a pulled
/// remote copy, so nothing here needs to be sync-aware. That also means a
/// photo attached on the desktop is never visible on the phone, and vice
/// versa -- by design, not by omission.
class PhotoAttachService {
  PhotoAttachService._(this._store);

  static PhotoAttachService _instance = PhotoAttachService._(null);

  /// The singleton instance.
  static PhotoAttachService get instance => _instance;

  BlobStore? _store;

  /// Redirects where picked photos are stored, so a test never touches the
  /// real store. Pass null to restore default behavior.
  @visibleForTesting
  static void resetForTesting({BlobStore? store}) {
    _instance = PhotoAttachService._(store);
  }

  Future<BlobStore> _resolveStore() async => _store ??= await openBlobStore();

  /// Opens [source] (camera or gallery) and stores the picked image.
  ///
  /// Returns the new blob key -- an absolute path on Android, an IndexedDB
  /// key in the browser -- or null if the user cancelled the picker.
  Future<String?> pickAndStore(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source);
    if (picked == null) return null;
    final store = await _resolveStore();
    // `readAsBytes` rather than a file copy: the browser's picker hands back
    // a blob URL with no filesystem behind it.
    return store.put(p.extension(picked.path), await picked.readAsBytes());
  }

  /// Returns the bytes stored under [key], or null when the photo is gone.
  ///
  /// Backs the web image widget, which cannot render from a path.
  Future<Uint8List?> readBytes(String key) async =>
      (await _resolveStore()).get(key);
}
