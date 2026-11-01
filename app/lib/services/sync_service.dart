/// Cross-device log sync orchestration for the diet_guard companion app.
///
/// Pulls every other device's pushed log from GitHub-backed dumb storage via
/// crdt_sync's shared transport ([GitHubClient]/[syncLog]), merges with the
/// local log via crdt_sync's shared CRDT scheme (`sync_merge.dart` adapts
/// [FoodEntry]s to/from [Record]), rebuilds the food bank, and pushes this
/// device's own merged log back up in the new Record-based wire format.
///
/// The daily budget syncs alongside the food log in the same tick (see
/// [_syncBudget]): a sibling `budget.json` per device, merged
/// last-writer-wins by edit time rather than union-of-immutable-entries,
/// since a budget (unlike a food-log entry) can be edited repeatedly.
library;

import 'dart:developer';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/export_keyring_default.dart';
import 'package:diet_guard_app/services/export_keyring_sync.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_body.dart';
import 'package:diet_guard_app/services/sync_budget_local.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_merge.dart';
import 'package:diet_guard_app/services/sync_merge_kuchnia.dart';
import 'package:diet_guard_app/services/sync_state_factory.dart';

const String _devicesDir = syncDevicesDir;

/// Runs one full sync tick: pull, merge, persist, push.
///
/// Returns the merged log as it now sits on disk locally. Propagates any
/// [GitHubSyncError] from the client for the caller (auto-sync / the manual
/// "Sync now" action) to decide how to report.
Future<DayLog> runSync(RemoteStore client, {SyncStateStore? stateStore}) async {
  final logService = LogStorageService.instance;
  final local = await logService.readLog();

  final mergedLog = await syncLog(
    client: client,
    deviceId: currentSyncDeviceId,
    legacyDeviceId: legacySyncDeviceId,
    pathPrefix: _devicesDir,
    localLog: dayLogToLog(local),
    encode: encodeLogForPush,
    decode: parseRemoteLog,
    filename: 'food_log.json',
    commitMessage: 'diet_guard_app sync',
    // Without this every sync re-downloads every peer's whole food log --
    // hundreds of KB -- whether or not anything changed, and re-pushes an
    // unchanged one. That is the traffic the Firebase free tier's monthly
    // budget depends on not happening.
    stateStore: stateStore ?? await openSyncStateStore(),
  );

  final merged = logToDayLog(mergedLog);

  await logService.writeLog(merged);
  await FoodBankService.instance.rebuildAndPersist(merged);
  await _syncBudget(client);
  await _syncFoodBank(client);
  await _syncManualBank(client);
  await _syncKuchniaCredential(client);
  await _syncExportKeys(client);
  await syncBody(client, devicesDir: _devicesDir);
  return merged;
}

/// Pulls, merges, persists and pushes the log-derived food bank.
///
/// Runs after the local rebuild above, so this device's records already
/// reflect the merged log; the merge then unions in whatever another device
/// knows, max-count winning per food. Mirrors `_sync._sync_food_bank`.
Future<void> _syncFoodBank(RemoteStore client) async {
  final merged = await syncLog(
    client: client,
    deviceId: currentSyncDeviceId,
    legacyDeviceId: legacySyncDeviceId,
    pathPrefix: _devicesDir,
    localLog: foodBankToLog(await FoodBankService.instance.readBank()),
    encode: encodeFoodBankForPush,
    decode: parseRemoteFoodBank,
    filename: 'food_bank.json',
    commitMessage: 'diet_guard_app sync',
  );
  await FoodBankService.instance.writeBank(logToFoodBank(merged));
}

/// Pulls, merges, persists and pushes the hand-curated food bank.
///
/// Curated entries are the one part of the bank that is not derivable from
/// the food log, so unlike `food_bank.json` they need a real merge:
/// last-writer-wins per food name by edit time, union across devices. Mirrors
/// `_sync._sync_manual_bank`.
Future<void> _syncManualBank(RemoteStore client) async {
  final local = await FoodBankService.instance.readManualBank();
  final merged = await syncLog(
    client: client,
    deviceId: currentSyncDeviceId,
    legacyDeviceId: legacySyncDeviceId,
    pathPrefix: _devicesDir,
    localLog: manualBankToLog(local),
    encode: encodeManualBankForPush,
    decode: parseRemoteManualBank,
    filename: 'food_bank_manual.json',
    commitMessage: 'diet_guard_app sync',
  );
  await FoodBankService.instance.applyMergedManualBank(logToManualBank(merged));
}

/// Pulls other devices' budgets, merges, applies the winner locally, pushes.
Future<void> _syncBudget(RemoteStore client) async {
  final mergedBudgetLog = await syncLog(
    client: client,
    deviceId: currentSyncDeviceId,
    legacyDeviceId: legacySyncDeviceId,
    pathPrefix: _devicesDir,
    localLog: localBudgetLog(),
    encode: encodeBudgetForPush,
    decode: parseRemoteBudget,
    filename: 'budget.json',
    commitMessage: 'diet_guard_app sync',
  );
  await applyBudgetLog(mergedBudgetLog);
}

/// Syncs the export keyring; best effort, since sync must not fail on it.
Future<void> _syncExportKeys(RemoteStore client) async {
  try {
    await syncExportKeys(
      client,
      keyring: defaultKeyring(),
      devicesDir: _devicesDir,
    );
  } on Object catch (error, stackTrace) {
    log(
      'export key sync failed',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Pulls peers' catering credentials, merges, applies the winner locally.
///
/// The phone runs its own catering importer, so it cannot fetch anything until
/// the panel password reaches it -- that is the whole reason this credential
/// syncs at all. It is plaintext on the wire, like the rest of the synced
/// state; see `sync_merge_kuchnia.dart`.
///
/// A device that has no credential contributes an empty log, so it neither
/// blocks nor clobbers a peer's real value -- it relays it. Mirrors
/// `diet_guard/_sync_kuchnia.py`.
Future<void> _syncKuchniaCredential(RemoteStore client) async {
  if (!KuchniaCredentialService.isInitialized) return;
  final merged = await syncLog(
    client: client,
    deviceId: currentSyncDeviceId,
    legacyDeviceId: legacySyncDeviceId,
    pathPrefix: _devicesDir,
    localLog: credentialToLog(
      KuchniaCredentialService.username,
      KuchniaCredentialService.password,
      KuchniaCredentialService.editedAt,
    ),
    encode: encodeCredentialForPush,
    decode: parseRemoteCredential,
    filename: 'kuchnia.json',
    commitMessage: 'diet_guard_app sync',
  );
  final credential = logToCredential(merged);
  if (credential == null) return;
  await KuchniaCredentialService.instance.applySynced(
    credential.username,
    credential.password,
    credential.editedAt,
  );
}
