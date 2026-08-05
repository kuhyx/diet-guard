import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:crdt_sync/crdt_sync_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// File holding the revision cache, beside the food log it describes.
const kSyncStateFileName = 'sync_state.json';

/// Opens the revision cache on a `dart:io` platform (Android).
///
/// Falls back to an in-memory cache when the platform channel is unavailable
/// (no binding under `flutter test`, or a plugin that failed to register).
/// Losing the cache costs one tick of extra traffic; failing here would take
/// sync down entirely, which is far worse than the thing being optimised.
Future<SyncStateStore> openSyncStateStore() async {
  try {
    final dir = await getApplicationSupportDirectory();
    return openSyncStateStoreIn(dir.path);
  } on Object {
    // Deliberately broader than Exception: an uninitialised binding raises a
    // FlutterError, which is an Error. Either way the platform is
    // unavailable and an in-memory cache is the right degradation.
    return InMemorySyncStateStore();
  }
}

/// Opens the revision cache rooted at [dirPath].
///
/// Lives next to the log it describes and must be cleared with it: skipping
/// an unchanged peer is only sound because that peer's records are already
/// merged into the local log, so state that outlived its log would skip peers
/// whose data had been lost.
SyncStateStore openSyncStateStoreIn(String dirPath) => PersistedSyncStateStore(
  FileLogPersistence(File(p.join(dirPath, kSyncStateFileName))),
);
