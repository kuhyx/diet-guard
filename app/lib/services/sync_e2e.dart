/// End-to-end encryption of everything this app syncs.
///
/// Every blob under `diet-guard-sync/devices-e2e` (food log, banks, budget,
/// catering credential, Body, export keyring) is sealed with a key derived
/// from the shared crdt-sync passphrase kept in the OS keystore; Firebase and
/// the GitHub mirror only see record ids, tombstones and clocks. The
/// wake-alarm weigh-ins live on their own prefix with their own header, so
/// they get a second store over the same backend.
///
/// Fail closed: without a usable key nothing is pulled or pushed. The old
/// plaintext `diet-guard-sync/devices` is copied over on open (picking up
/// writes from builds not yet migrated) and never written or deleted here.
/// Mirrors `diet_guard/_sync_e2e.py`.
library;

import 'dart:developer';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:crdt_sync_flutter/crdt_sync_flutter.dart'
    show openEncryptedStoreFromKeystore;
import 'package:flutter/foundation.dart';

/// The plaintext prefix every pre-E2E build wrote; only the copy reads it.
const legacyDevicesDir = 'diet-guard-sync/devices';

/// Where the wake-alarm app published before E2E.
const legacyWakeAlarmDir = 'wake-alarm-sync/devices';

/// Argon2id cost for a header this device creates; only tests lower it.
@visibleForTesting
Argon2Params e2eArgon2Params = Argon2Params.recommended;

/// Whether the last open found no usable key, for the lock button.
final ValueNotifier<bool> syncLocked = ValueNotifier<bool>(false);

/// Thrown instead of syncing when end-to-end encryption has no usable key.
class SyncLockedException implements Exception {
  /// Creates the exception for [reason].
  const SyncLockedException(this.reason);

  /// Why the store is locked.
  final E2eLockReason reason;

  @override
  String toString() => 'sync locked (${reason.name})';
}

Future<E2eState> _open(RemoteStore backend, String oldPrefix) =>
    openEncryptedStoreFromKeystore(
      store: backend,
      oldPrefix: oldPrefix,
      params: e2eArgon2Params,
    );

/// The encrypted diet_guard store over [backend], the outermost store.
///
/// Throws [SyncLockedException] when locked, so no caller can fall through
/// to a plaintext sync.
Future<RemoteStore> openDietGuardStore(RemoteStore backend) async {
  final state = await _open(backend, legacyDevicesDir);
  syncLocked.value = state is! E2eReady;
  if (state is E2eReady) return state.store;
  throw SyncLockedException(
    state is E2eLocked ? state.reason : E2eLockReason.badHeader,
  );
}

/// The encrypted wake-alarm store over [backend], or null when locked or
/// unreachable.
///
/// Its weigh-ins are optional input to the diet sync, so nothing here may
/// fail the tick: a lock or a transport error skips only the ingest.
Future<RemoteStore?> openWakeAlarmStore(RemoteStore backend) async {
  try {
    final state = await _open(backend, legacyWakeAlarmDir);
    return state is E2eReady ? state.store : null;
  } on Object catch (error, stackTrace) {
    log(
      'wake-alarm store unavailable; skipping weigh-ins',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}
