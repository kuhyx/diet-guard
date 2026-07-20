/// IndexedDB-backed [BlobStore], independent of how the database was opened.
///
/// Split from `blob_store_web.dart` so a plain VM test can drive it against
/// `idb_shim`'s in-memory backend: the browser factory
/// (`idb_browser.dart`) cannot be imported outside a web compile, and photos
/// have no other copy anywhere -- they never sync.
library;

import 'dart:typed_data';

import 'package:diet_guard_app/services/blob_store.dart';
import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:http/http.dart' as http;
import 'package:idb_shim/idb_shim.dart';
import 'package:uuid/uuid.dart';

/// [BlobStore] keeping photo bytes in IndexedDB, mirrored to the desktop
/// wrapper's on-disk copy.
///
/// Photos never sync (`imagePath` is stripped before push and ignored on
/// pull), so the wrapper mirror is the *only* thing standing between a wiped
/// Chrome profile and permanently losing them -- unlike the food log, which
/// GitHub would eventually restore.
class IndexedDbBlobStore implements BlobStore {
  /// Creates a store over an already-open [database], mirroring to [baseUrl].
  IndexedDbBlobStore(
    this._database, {
    this.baseUrl = desktopWrapperOrigin,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  final Database _database;
  final http.Client _client;

  /// Origin of the desktop wrapper.
  final String baseUrl;

  /// Object store holding one entry per photo.
  static const storeName = 'blobs';

  /// IndexedDB database name.
  static const databaseName = 'diet_guard_blobs';

  @override
  Future<String> put(String extension, Uint8List bytes) async {
    final key = '${const Uuid().v4()}$extension';
    final txn = _database.transaction(storeName, idbModeReadWrite);
    await txn.objectStore(storeName).put(bytes, key);
    await txn.completed;
    await _writeMirror(key, bytes);
    return key;
  }

  @override
  Future<Uint8List?> get(String key) async {
    final txn = _database.transaction(storeName, idbModeReadOnly);
    final value = await txn.objectStore(storeName).getObject(key);
    await txn.completed;
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    // Missing locally: recover from the wrapper's disk copy (cleared profile).
    return _readMirror(key);
  }

  Future<Uint8List?> _readMirror(String key) async {
    try {
      final response = await _client.get(_uriFor(key));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      return response.bodyBytes;
    } on Exception {
      return null;
    }
  }

  Future<void> _writeMirror(String key, Uint8List bytes) async {
    try {
      await _client.post(_uriFor(key), body: bytes);
    } on Exception {
      // Best-effort by design, like the document mirror.
    }
  }

  Uri _uriFor(String key) => Uri.parse('$baseUrl${WrapperPaths.blobs}$key');
}
