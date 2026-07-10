/// Cross-device log sync orchestration for the diet_guard companion app.
///
/// Pulls every other device's pushed log from GitHub-backed dumb storage via
/// crdt_sync's shared transport ([GitHubClient]/[syncLog]), merges with the
/// local log via crdt_sync's shared CRDT scheme (`sync_merge.dart` adapts
/// [FoodEntry]s to/from [Record]), rebuilds the food bank, and pushes this
/// device's own merged log back up in the new Record-based wire format. One
/// phone-specific step, with no PC-side equivalent: a pulled copy of an
/// entry never carries `imagePath` (stripped before push, meaningless on
/// another device), so it must not null out a local photo attachment for
/// the same `id` (plan decision 10).
library;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_merge.dart';

const _devicesDir = 'diet-guard-sync/devices';

/// This device's id in the `diet-guard-sync/devices/<id>/food_log.json`
/// layout. The PC pushes under `pc` (`SYNC_DEVICE_ID` in
/// `diet_guard/_constants.py`); the phone is the only other device in this
/// design.
const phoneDeviceId = 'phone';

/// Runs one full sync tick: pull, merge, preserve photos, persist, push.
///
/// Returns the merged log as it now sits on disk locally. Propagates any
/// [GitHubSyncError] from the client for the caller (auto-sync / the manual
/// "Sync now" action) to decide how to report.
Future<DayLog> runSync(GitHubClient client) async {
  final logService = LogStorageService.instance;
  final local = await logService.readLog();
  final localImagePaths = _imagePathsById(local);

  final mergedLog = await syncLog(
    client: client,
    deviceId: phoneDeviceId,
    pathPrefix: _devicesDir,
    localLog: dayLogToLog(local),
    encode: encodeLogForPush,
    decode: parseRemoteLog,
    filename: 'food_log.json',
    commitMessage: 'diet_guard_app sync',
  );

  var merged = logToDayLog(mergedLog);
  merged = _preserveLocalImagePaths(merged, localImagePaths);

  await logService.writeLog(merged);
  await FoodBankService.instance.rebuildAndPersist(merged);
  return merged;
}

Map<String, String> _imagePathsById(DayLog log) {
  final result = <String, String>{};
  for (final entries in log.values) {
    for (final entry in entries) {
      final id = entry.id;
      final imagePath = entry.imagePath;
      if (id != null && imagePath != null) result[id] = imagePath;
    }
  }
  return result;
}

DayLog _preserveLocalImagePaths(
  DayLog log,
  Map<String, String> imagePathsById,
) {
  if (imagePathsById.isEmpty) return log;
  return {
    for (final mapEntry in log.entries)
      mapEntry.key: [
        for (final entry in mapEntry.value)
          _withPreservedImagePath(entry, imagePathsById),
      ],
  };
}

FoodEntry _withPreservedImagePath(
  FoodEntry entry,
  Map<String, String> imagePathsById,
) {
  if (entry.imagePath != null) return entry;
  final preserved = imagePathsById[entry.id];
  if (preserved == null) return entry;
  return entry.copyWithImagePath(preserved);
}
