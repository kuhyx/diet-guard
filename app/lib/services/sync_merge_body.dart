/// Body document <-> crdt_sync Record adapters.
///
/// Wire format (see `docs/DOCS-body.md`), one Log per device-pushed
/// `body.json`:
///
/// * `profile`: fields `birth`, `height_cm`, `sex`, `tbl_act`, `tbl_rates`,
///   each with its own clock, so editing height on one device cannot revert
///   a birth date edited on the other. Unknown fields are relayed as-is.
/// * `w:<YYYY-MM-DD>`: field `kg` = `{"kg": number|null, "src": string}`.
/// * `bf:<YYYY-MM-DD>`: field `pct` = `{"pct": number|null}`.
/// * `st:<YYYY-MM-DD>`: field `n` = `{"n": int}` (phone-written steps).
/// * `activity`: field `sessions` = the PC's published workouts.
///
/// Every clock's wall time is the part's own `t` stamp -- the same
/// determinism trick as `sync_merge_budget.dart`, so re-syncing an unchanged
/// document is a no-op. KEEP IN SYNC WITH `diet_guard/sync_merge/_body.py`.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/body_document.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';

/// The profile record's id.
const profileRecordId = 'profile';

/// Weight record id prefix.
const weightRecordPrefix = 'w:';

/// Body-fat record id prefix.
const bodyFatRecordPrefix = 'bf:';

/// Steps record id prefix.
const stepsRecordPrefix = 'st:';

/// The activity record's id.
const activityRecordId = 'activity';

Hlc _hlc(String t) =>
    Hlc.newTick(currentSyncDeviceId, wallTimeMsOverride: stampMillis(t));

/// Rebuilds an edit stamp from a merged clock: local ISO, with milliseconds
/// only when the clock has them, so a whole-second stamp round-trips
/// byte-for-byte and re-derives the same clock.
String stampFromHlc(Hlc hlc) {
  final moment = DateTime.fromMillisecondsSinceEpoch(hlc.wallTimeMs);
  if (hlc.wallTimeMs % 1000 == 0) return isoLocalSeconds(moment);
  return moment.toUtc().toIso8601String();
}

/// Converts the local document into a [Log].
Log bodyToLog(BodyDocument doc) {
  final log = <String, Record>{};
  if (doc.profile.isNotEmpty) {
    log[profileRecordId] = Record(
      id: profileRecordId,
      fields: {
        for (final entry in doc.profile.entries)
          entry.key: (entry.value.value, _hlc(entry.value.t)),
      },
    );
  }
  for (final entry in doc.weights.entries) {
    final id = '$weightRecordPrefix${entry.key}';
    log[id] = Record(
      id: id,
      fields: {
        'kg': (
          {'kg': entry.value.kg, 'src': entry.value.src},
          _hlc(entry.value.t),
        ),
      },
    );
  }
  for (final entry in doc.bodyFat.entries) {
    final id = '$bodyFatRecordPrefix${entry.key}';
    log[id] = Record(
      id: id,
      fields: {
        'pct': ({'pct': entry.value.pct}, _hlc(entry.value.t)),
      },
    );
  }
  for (final entry in doc.steps.entries) {
    final id = '$stepsRecordPrefix${entry.key}';
    log[id] = Record(
      id: id,
      fields: {
        'n': ({'n': entry.value.n}, _hlc(entry.value.t)),
      },
    );
  }
  final activity = doc.activity;
  if (activity != null) {
    log[activityRecordId] = Record(
      id: activityRecordId,
      fields: {'sessions': (activity.sessions, _hlc(activity.t))},
    );
  }
  return log;
}

/// Every profile field, as merged; the service validates on read.
Map<String, Stamped> _profile(Record? record) => {
  if (record != null)
    for (final entry in record.fields.entries)
      entry.key: Stamped(entry.value.$1, stampFromHlc(entry.value.$2)),
};

/// Converts a merged [Log] back into a document. Malformed parts are skipped.
BodyDocument logToBody(Log log) {
  final weights = <String, WeightEntry>{};
  for (final record in log.values) {
    if (record.deleted || !record.id.startsWith(weightRecordPrefix)) continue;
    final day = record.id.substring(weightRecordPrefix.length);
    final field = record.fields['kg'];
    if (!isDateKey(day) || field == null) continue;
    final entry = parseWeightValue(field.$1, stampFromHlc(field.$2));
    if (entry != null) weights[day] = entry;
  }
  final bodyFat = <String, BodyFatEntry>{};
  for (final record in log.values) {
    if (record.deleted || !record.id.startsWith(bodyFatRecordPrefix)) continue;
    final day = record.id.substring(bodyFatRecordPrefix.length);
    final field = record.fields['pct'];
    if (!isDateKey(day) || field == null) continue;
    final entry = parseBodyFatValue(field.$1, stampFromHlc(field.$2));
    if (entry != null) bodyFat[day] = entry;
  }
  final steps = <String, StepsEntry>{};
  for (final record in log.values) {
    if (record.deleted || !record.id.startsWith(stepsRecordPrefix)) continue;
    final day = record.id.substring(stepsRecordPrefix.length);
    final field = record.fields['n'];
    if (!isDateKey(day) || field == null) continue;
    final entry = parseStepsValue(field.$1, stampFromHlc(field.$2));
    if (entry != null) steps[day] = entry;
  }
  final activityField = log[activityRecordId]?.fields['sessions'];
  final sessions = activityField?.$1;
  return BodyDocument(
    profile: _profile(log[profileRecordId]),
    weights: weights,
    bodyFat: bodyFat,
    steps: steps,
    activity: activityField == null || sessions is! List
        ? null
        : ActivityData(
            sessions: List<Object?>.from(sessions),
            t: stampFromHlc(activityField.$2),
          ),
  );
}

/// Parses one device's pushed `body.json`. Throws [FormatException] or
/// [TypeError] on a corrupt push, which `syncLog` treats as unparsable.
Log parseRemoteBody(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map) {
    throw const FormatException('top-level body payload is not an object');
  }
  return raw.cast<String, dynamic>().map(
    (id, data) => MapEntry(id, Record.fromJson(data as Map<String, dynamic>)),
  );
}

/// Serializes a merged body [Log] for push.
String encodeBodyForPush(Log log) => jsonEncode({
  for (final entry in log.entries) entry.key: entry.value.toJson(),
});
