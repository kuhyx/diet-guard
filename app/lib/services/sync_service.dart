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

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_merge.dart';
import 'package:diet_guard_app/services/sync_merge_schedule.dart';
import 'package:diet_guard_app/services/sync_state_factory.dart';

const _devicesDir = 'diet-guard-sync/devices';

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
///
/// Reuses [syncLog] (it always pushes the merged result, even an empty
/// one -- harmless and consistent with the food-log sync above). This
/// device contributes nothing to the merge until the goal has been
/// explicitly set at least once (see
/// [AppSettingsService.dailyKcalGoalUpdatedAt]), so a fresh install's
/// unset 2200 default can never spuriously outrank a real budget synced
/// from elsewhere.
Future<void> _syncBudget(RemoteStore client) async {
  final updatedAt = AppSettingsService.dailyKcalGoalUpdatedAt;
  final scheduleEntries = MealScheduleService.history.entries;
  // `budgetToLog` returns an empty Log for a null record, which would also
  // drop the `sched:` fields. A device that has edited its schedule but never
  // its budget still has something to contribute, so synthesise a record from
  // the schedule's own edit time in that case. Its `value` carries the
  // unset-default budget, but that loses every LWW race against a device that
  // has actually set one, because this stamp is older than any real edit.
  final scheduleStamp = MealScheduleService.updatedAt;
  final recordStamp =
      updatedAt ?? (scheduleEntries.isEmpty ? null : scheduleStamp);
  final localRecord = recordStamp == null
      ? null
      : <String, dynamic>{
          'v': 2,
          'b': AppSettingsService.dailyKcalGoal,
          't': (updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .toIso8601String(),
        };

  final mergedBudgetLog = await syncLog(
    client: client,
    deviceId: currentSyncDeviceId,
    legacyDeviceId: legacySyncDeviceId,
    pathPrefix: _devicesDir,
    localLog: budgetToLog(
      localRecord,
      BudgetHistoryService.schedule.entries,
      scheduleEntries,
    ),
    encode: encodeBudgetForPush,
    decode: parseRemoteBudget,
    filename: 'budget.json',
    commitMessage: 'diet_guard_app sync',
  );

  // The history merges by field union, so it is applied unconditionally --
  // independently of whether the scalar budget resolved to anything.
  await BudgetHistoryService.instance.applyMerged(
    logToHistory(mergedBudgetLog),
  );
  // Same reasoning for the meal schedule: field-union merge, so applied
  // regardless of how the scalar budget resolved.
  if (MealScheduleService.isInitialized) {
    await MealScheduleService.instance.applyMerged(
      logToScheduleHistory(mergedBudgetLog),
      updatedAt: scheduleStamp,
    );
  }

  final merged = logToBudget(mergedBudgetLog);
  final mergedKcal = merged?['b'];
  if (merged == null || mergedKcal is! int) return;
  await AppSettingsService.instance.applySyncedBudget(
    mergedKcal,
    updatedAt: DateTime.tryParse(merged['t'] as String? ?? ''),
  );
}
