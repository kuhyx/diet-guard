/// The `export_keys` document: the keyring as a crdt_sync log.
///
/// One record per key id, never deleted, so the merge is a plain union and
/// concurrent mints on two devices both survive. See `export_keyring.dart`
/// for the plaintext-at-Firebase caveat.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/export_keyring.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';

const _keyField = 'k';
const _createdField = 't';

Log _toLog(Iterable<ExportKey> keys, String deviceId) => {
  for (final key in keys)
    key.kid: Record(
      id: key.kid,
      fields: {
        _keyField: (
          base64Encode(key.bytes),
          Hlc.newTick(
            deviceId,
            wallTimeMsOverride: key.createdAt.millisecondsSinceEpoch,
          ),
        ),
        _createdField: (
          key.createdAt.toIso8601String(),
          Hlc.newTick(
            deviceId,
            wallTimeMsOverride: key.createdAt.millisecondsSinceEpoch,
          ),
        ),
      },
    ),
};

List<ExportKey> _fromLog(Log log) {
  final keys = <ExportKey>[];
  for (final record in log.values) {
    try {
      keys.add(
        ExportKey(
          record.id,
          base64Decode(record.fields[_keyField]!.$1! as String),
          DateTime.parse(record.fields[_createdField]!.$1! as String).toUtc(),
        ),
      );
    } on Object {
      continue; // a malformed peer record is skipped, never fatal
    }
  }
  return keys;
}

/// Pulls peers' keys into [keyring], pushes this device's keys.
///
/// Runs even when the ring is empty, so a fresh device still receives keys.
Future<void> syncExportKeys(
  RemoteStore client, {
  required ExportKeyring keyring,
  required String devicesDir,
  String? deviceId,
}) async {
  final id = deviceId ?? currentSyncDeviceId;
  final merged = await syncLog(
    client: client,
    deviceId: id,
    legacyDeviceId: deviceId == null ? legacySyncDeviceId : null,
    pathPrefix: devicesDir,
    localLog: _toLog(await keyring.all(), id),
    encode: (log) => jsonEncode({
      for (final entry in log.entries) entry.key: entry.value.toJson(),
    }),
    decode: (text) => (jsonDecode(text) as Map).cast<String, dynamic>().map(
      (kid, data) =>
          MapEntry(kid, Record.fromJson(data as Map<String, dynamic>)),
    ),
    filename: 'export_keys.json',
    commitMessage: 'diet_guard_app sync',
  );
  await keyring.mergeKeys(_fromLog(merged));
}
