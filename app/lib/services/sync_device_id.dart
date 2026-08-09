/// This install's persisted sync device id.
library;

import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// SharedPreferences key holding this install's device id.
///
/// The same key the sibling apps (`todo`, `home_inventory`, `wake_alarm`)
/// use for the same purpose.
const kSyncDeviceIdKey = 'crdt.nodeId';

String? _cached;

/// This install's sync device id, for HLC stamping and the pushed path.
///
/// Synchronous because [Hlc] stamping is synchronous and threading a future
/// through every merge adapter would be a large change for no benefit. Call
/// [initSyncDeviceId] once during startup, before any sync or merge runs;
/// until then this falls back to the compile-time role constant
/// ([syncDeviceId]) so a caller that forgets still writes a *valid* id rather
/// than crashing -- it just writes the pre-migration one.
String get currentSyncDeviceId => _cached ?? syncDeviceId;

/// The id this install pushed under before migrating to a persisted uuid.
///
/// Passed to `syncLog` as its legacy id so the log already sitting at
/// `devices/<legacy>/` is treated as this device's own rather than a peer's;
/// without it every tick re-downloads and re-merges this device's own
/// pre-migration history. Set to null once that path has been reclaimed.
const String legacySyncDeviceId = syncDeviceId;

/// Loads (or mints and persists) this install's device id.
///
/// A per-install uuid rather than the fixed `phone`/`desktop` role constant:
/// two installs sharing an id overwrite each other's pushed file on every
/// tick, and a reinstall would inherit the previous install's CRDT identity.
///
/// Idempotent -- safe to call more than once.
Future<String> initSyncDeviceId({SharedPreferences? prefs}) async {
  final store = prefs ?? await SharedPreferences.getInstance();
  final existing = store.getString(kSyncDeviceIdKey);
  if (existing != null && existing.isNotEmpty) {
    _cached = existing;
    return existing;
  }
  final minted = const Uuid().v4();
  await store.setString(kSyncDeviceIdKey, minted);
  _cached = minted;
  return minted;
}

/// Resets the cached id. Test-only.
void resetSyncDeviceIdForTest() => _cached = null;
