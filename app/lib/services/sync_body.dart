/// The Body document's part of a sync tick.
///
/// Its own file because `sync_service.dart` is near the repo's 250-line cap.
/// First ingests the wake-alarm weigh-ins (never throws), then pulls peers'
/// `body.json`, merges last-writer-wins per field, applies the result locally
/// and pushes. Mirrors `diet_guard/_sync_body.py`.
library;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_merge_body.dart';
import 'package:diet_guard_app/services/wake_alarm_weights.dart';

/// Runs the Body sync against [client], under [devicesDir].
///
/// No-ops when [BodyService] is uninitialised (a widget test, or an isolate
/// that never loaded it), so it can neither publish nor clobber anything.
Future<void> syncBody(RemoteStore client, {required String devicesDir}) async {
  if (!BodyService.isInitialized) return;
  await ingestWakeAlarmWeights(client);
  final merged = await syncLog(
    client: client,
    deviceId: currentSyncDeviceId,
    legacyDeviceId: legacySyncDeviceId,
    pathPrefix: devicesDir,
    localLog: bodyToLog(BodyService.instance.document),
    encode: encodeBodyForPush,
    decode: parseRemoteBody,
    filename: 'body.json',
    commitMessage: 'diet_guard_app sync',
  );
  if (merged.isEmpty) return;
  await BodyService.instance.applyMerged(logToBody(merged));
}
