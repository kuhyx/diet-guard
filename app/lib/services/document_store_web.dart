/// Opens the IndexedDB-backed [DocumentStore] in the browser.
library;

import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/document_store_indexeddb.dart';
import 'package:idb_shim/idb_browser.dart';

/// Opens (creating if needed) the IndexedDB-backed document store.
// coverage:ignore-start
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

// coverage:ignore-end
