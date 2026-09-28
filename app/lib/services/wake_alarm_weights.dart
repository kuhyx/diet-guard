/// Morning weigh-ins from the wake-alarm app, as Body weight candidates.
///
/// The wake-alarm phone app publishes
/// `wake-alarm-sync/devices/<id>/alarm.json`: a crdt_sync Log whose
/// `alarm` record carries `fields[name] = [value, hlc]`. Two fields hold
/// weights:
///
/// * `latest_weight_kg` = `{"date", "kg"}` -- stamped with **that field's**
///   clock, so a re-typed weigh-in is newer and wins;
/// * `morning_sessions` = recent sessions with `date` and `weight_kg` --
///   stamped `<date>T00:00:00+00:00`, so they only fill gaps: the list is
///   republished every morning with a new clock, and using that clock would
///   overwrite every manual correction daily.
///
/// Pure: raw JSON in, candidates out; [ingestWakeAlarmWeights] is the impure
/// edge. KEEP IN SYNC WITH the PC's ingestion in `diet_guard/_body_ingest.py`.
library;

import 'dart:convert';
import 'dart:developer';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/sync_merge_body.dart';

/// Where the wake-alarm app publishes, one directory per device.
const wakeAlarmDevicesDir = 'wake-alarm-sync/devices';

const _latestField = 'latest_weight_kg';
const _sessionsField = 'morning_sessions';

List<Object?>? _pair(Map<Object?, Object?> fields, String name) {
  final pair = fields[name];
  return pair is List && pair.length >= 2 ? pair : null;
}

void _offer(Map<String, WeightEntry> out, Object? day, Object? kg, String t) {
  if (!isDateKey(day) || !plausibleKg(kg)) return;
  final key = day! as String;
  final current = out[key];
  if (current != null && stampMillis(current.t) >= stampMillis(t)) return;
  out[key] = WeightEntry(kg: (kg! as num).toDouble(), src: 'phone', t: t);
}

void _fromLog(Map<String, WeightEntry> out, Object? log) {
  if (log is! Map) return;
  final record = log['alarm'];
  final fields = record is Map ? record['fields'] : null;
  if (fields is! Map) return;
  final latest = _pair(fields, _latestField);
  final value = latest?[0];
  final hlcText = latest?[1];
  if (value is Map && hlcText is String) {
    try {
      final stamp = stampFromHlc(Hlc.fromStr(hlcText));
      _offer(out, value['date'], value['kg'], stamp);
    } on FormatException {
      // An unreadable clock makes the weigh-in unrankable; skip it.
    }
  }
  final sessions = _pair(fields, _sessionsField)?[0];
  if (sessions is! List) return;
  for (final session in sessions) {
    if (session is! Map) continue;
    final day = session['date'];
    _offer(out, day, session['weight_kg'], '${day}T00:00:00+00:00');
  }
}

/// Weight candidates by day from every device's raw `alarm.json`, newest
/// stamp per day. Unparsable devices are skipped.
Map<String, WeightEntry> wakeAlarmCandidates(List<(String, String)> published) {
  final out = <String, WeightEntry>{};
  for (final (_, raw) in published) {
    try {
      _fromLog(out, jsonDecode(raw));
    } on FormatException {
      continue;
    }
  }
  return out;
}

/// Reads every wake-alarm device's record and applies its weigh-ins.
///
/// Never throws: a missing or unreadable wake-alarm namespace must not fail
/// the diet sync tick it runs inside. Returns whether anything changed.
Future<bool> ingestWakeAlarmWeights(RemoteStore client) async {
  if (!BodyService.isInitialized) return false;
  try {
    final published = <(String, String)>[];
    for (final device in await client.listDirectory(wakeAlarmDevicesDir)) {
      final text = await client.getFileText(
        '$wakeAlarmDevicesDir/$device/alarm.json',
      );
      if (text != null) published.add((device, text));
    }
    return await BodyService.instance.applyCandidates(
      wakeAlarmCandidates(published),
    );
  } on Object catch (error, stackTrace) {
    log(
      'wake-alarm weigh-in ingestion failed; continuing the sync',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  }
}
