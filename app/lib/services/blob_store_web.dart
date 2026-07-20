/// Opens the IndexedDB-backed [BlobStore] in the browser.
library;

import 'package:diet_guard_app/services/blob_store.dart';
import 'package:diet_guard_app/services/blob_store_indexeddb.dart';
import 'package:idb_shim/idb_browser.dart';

/// Opens (creating if needed) the IndexedDB-backed blob store.
// coverage:ignore-start
Future<BlobStore> openBlobStore() async {
  final database = await idbFactoryBrowser.open(
    IndexedDbBlobStore.databaseName,
    version: 1,
    onUpgradeNeeded: (event) {
      final db = event.database;
      if (!db.objectStoreNames.contains(IndexedDbBlobStore.storeName)) {
        db.createObjectStore(IndexedDbBlobStore.storeName);
      }
    },
  );
  return IndexedDbBlobStore(database);
}

// coverage:ignore-end
