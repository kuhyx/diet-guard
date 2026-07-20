/// IndexedDB-backed [DocumentStore] used by the browser-hosted desktop app.
library;

import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:http/http.dart' as http;
import 'package:idb_shim/idb_browser.dart';

/// [DocumentStore] backed by IndexedDB, mirrored to the desktop wrapper's
/// on-disk copy.
///
/// IndexedDB rather than `localStorage`: the latter caps at roughly 5-10MB per
/// origin and is evicted more eagerly, and these documents are the desktop
/// device's primary copy of the food log.
///
/// The wrapper mirror is the recovery path for a wiped Chrome profile. GitHub
/// sync would eventually restore the log too, but only what other devices have
/// already seen -- a meal logged on this desktop and never pushed exists
/// nowhere else. Reads fall back to the mirror when IndexedDB is empty; writes
/// to it are best-effort so the app still works opened in a plain browser tab
/// with no wrapper running.
class IndexedDbDocumentStore implements DocumentStore {
  /// Creates a store over an already-open [database], mirroring to [baseUrl].
  IndexedDbDocumentStore(
    this._database, {
    this.baseUrl = desktopWrapperOrigin,
    http.Client? httpClient,
  }) : _client = httpClient ?? http.Client();

  final Database _database;
  final http.Client _client;

  /// Origin of the desktop wrapper.
  final String baseUrl;

  /// Object store holding one entry per document name.
  static const storeName = 'documents';

  /// IndexedDB database name.
  static const databaseName = 'diet_guard';

  @override
  Future<String?> read(String name) async {
    final txn = _database.transaction(storeName, idbModeReadOnly);
    final value = await txn.objectStore(storeName).getObject(name);
    await txn.completed;
    if (value is String) return value;
    // Empty IndexedDB: either a first run or a cleared profile. Recover from
    // the wrapper's disk copy rather than silently starting from nothing.
    return _readMirror(name);
  }

  @override
  Future<void> write(String name, String contents) async {
    final txn = _database.transaction(storeName, idbModeReadWrite);
    await txn.objectStore(storeName).put(contents, name);
    await txn.completed;
    await _writeMirror(name, contents);
  }

  Future<String?> _readMirror(String name) async {
    try {
      final response = await _client.get(_uriFor(name));
      if (response.statusCode != 200 || response.body.isEmpty) return null;
      return response.body;
    } on Exception {
      return null;
    }
  }

  Future<void> _writeMirror(String name, String contents) async {
    try {
      await _client.post(_uriFor(name), body: contents);
    } on Exception {
      // Best-effort by design; see the class docs.
    }
  }

  Uri _uriFor(String name) =>
      Uri.parse('$baseUrl${WrapperPaths.documents}$name');
}

/// Opens (creating if needed) the IndexedDB-backed document store.
Future<DocumentStore> openDocumentStore() async {
  final database = await idbFactoryBrowser.open(
    IndexedDbDocumentStore.databaseName,
    version: 1,
    onUpgradeNeeded: (event) {
      final db = event.database;
      if (!db.objectStoreNames.contains(IndexedDbDocumentStore.storeName)) {
        db.createObjectStore(IndexedDbDocumentStore.storeName);
      }
    },
  );
  return IndexedDbDocumentStore(database);
}
