/// Tests for the revision cache and the backend choice.
///
/// The cache is what keeps a sync tick from re-downloading every peer's whole
/// food log when nothing changed, so "does it survive a restart" and "does a
/// dead platform channel take sync down with it" are the behaviours worth
/// pinning.
@TestOn('vm')
library;

import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/firebase_client.dart';
import 'package:diet_guard_app/services/sync_state_factory_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A do-nothing [RemoteStore], standing in for the GitHub client.
class _StubRemote implements RemoteStore {
  @override
  Future<List<String>> listDirectory(String path) async => [];

  @override
  Future<String?> getFileText(String path) async => null;

  @override
  Future<void> putFileText(
    String path,
    String text, {
    required String message,
  }) async {}

  @override
  Future<void> deleteFile(String path, {String message = ''}) async {}

  @override
  Future<bool> canAccessRemote() async => true;

  @override
  void close() {}
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dg_state_');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('persists revisions across a restart', () async {
    // A fresh store instance stands in for the next app launch: an in-memory
    // cache would forget every peer and re-download all of them.
    await openSyncStateStoreIn(dir.path).save(
      const SyncState(pushedRev: 'mine', peerRevs: {'pc': 'theirs'}),
    );

    final reloaded = await openSyncStateStoreIn(dir.path).load();

    expect(reloaded.pushedRev, 'mine');
    expect(reloaded.peerRevs, {'pc': 'theirs'});
  });

  test('writes beside the log it describes', () async {
    await openSyncStateStoreIn(dir.path).save(const SyncState(pushedRev: 'x'));

    expect(File(p.join(dir.path, kSyncStateFileName)).existsSync(), isTrue);
  });

  test('degrades to memory when the platform channel is unavailable', () async {
    // No binding under `flutter test`. Losing the cache costs one tick of
    // extra traffic; failing would take sync down entirely.
    final store = await openSyncStateStore();

    expect(store, isA<SyncStateStore>());
    expect((await store.load()).pushedRev, isNull);
  });

  test('stays on GitHub when Firebase is not set up', () async {
    // The pre-migration path, and the rollback. Reaching the keystore without
    // a binding must read as "not configured", not as an error.
    final github = _StubRemote();

    expect(await syncBackend(github), same(github));
  });
}
