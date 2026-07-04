/// Cross-device log sync orchestration for the diet_guard companion app.
///
/// Pulls every other device's pushed log from GitHub-backed dumb storage
/// ([GitHubClient]), merges with the local log ([mergeLogs]), rebuilds the
/// food bank, and pushes this device's own merged log back up. A **new**
/// implementation, not a port of `~/todo`'s CRDT-based sync (this app has no
/// CRDT layer) -- a Dart twin of the same pull-merge-rebuild-push sequence
/// as `diet_guard/_sync.py`, plus one phone-specific step: a pulled copy of
/// an entry never carries `imagePath` (stripped before push, meaningless on
/// another device), so it must not null out a local photo attachment for
/// the same `id` (plan decision 10).
library;

import 'dart:convert';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/github_client.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_merge.dart';

const _devicesDir = 'devices';

/// This device's id in the `devices/<id>/food_log.json` layout. The PC
/// pushes under `pc` (`SYNC_DEVICE_ID` in `diet_guard/_constants.py`); the
/// phone is the only other device in this design.
const phoneDeviceId = 'phone';

String _deviceLogPath(String deviceId) =>
    '$_devicesDir/$deviceId/food_log.json';

/// Runs one full sync tick: pull, merge, preserve photos, persist, push.
///
/// Returns the merged log as it now sits on disk locally. Propagates any
/// [GitHubApiException] from the client for the caller (auto-sync / the
/// manual "Sync now" action) to decide how to report.
Future<DayLog> runSync(GitHubClient client) async {
  final logService = LogStorageService.instance;
  final local = await logService.readLog();
  final localImagePaths = _imagePathsById(local);

  var merged = local;
  for (final deviceId in await client.listEntryNames(_devicesDir)) {
    if (deviceId == phoneDeviceId) continue;
    final text = await client.getFileText(_deviceLogPath(deviceId));
    if (text == null) continue;
    final remoteLog = _decodeRemoteLog(text);
    if (remoteLog == null) continue;
    merged = mergeLogs(merged, remoteLog);
  }

  merged = _preserveLocalImagePaths(merged, localImagePaths);

  await logService.writeLog(merged);
  await FoodBankService.instance.rebuildAndPersist(merged);

  await client.putFileText(
    _deviceLogPath(phoneDeviceId),
    _encodeForPush(merged),
    sha: await _ownFileSha(client),
    message: 'diet_guard_app sync',
  );
  return merged;
}

/// Returns this device's current `food_log.json` sha if it has pushed
/// before, so [GitHubClient.putFileText] updates rather than creates.
Future<String?> _ownFileSha(GitHubClient client) async {
  final files = await client.listDirectory('$_devicesDir/$phoneDeviceId');
  for (final file in files) {
    if (file.name == 'food_log.json') return file.sha;
  }
  return null;
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

/// Parses a device's pushed log, mirroring `_sync._pull_remote_logs`'s
/// tolerance for a corrupt/truncated push: an unparsable file is skipped
/// (returns null) rather than aborting the whole sync tick.
DayLog? _decodeRemoteLog(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final result = <String, List<FoodEntry>>{};
  for (final mapEntry in decoded.entries) {
    final key = mapEntry.key;
    final value = mapEntry.value;
    if (key is! String || value is! List) continue;
    result[key] = value
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => FoodEntry.fromJson(m.cast<String, dynamic>()))
        .toList();
  }
  return result;
}

/// Serializes the full merged log for push via [FoodEntry.toSyncJson],
/// which excludes [FoodEntry.imagePath] (phone-local only) and `hmac` (the
/// PC re-signs every persisted entry on its own next sync tick regardless).
String _encodeForPush(DayLog log) {
  final encoded = <String, Object?>{
    for (final mapEntry in log.entries)
      mapEntry.key: mapEntry.value.map((e) => e.toSyncJson()).toList(),
  };
  return jsonEncode(encoded);
}
