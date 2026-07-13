/// Entry <-> crdt_sync.Record adapters for diet_guard_app's cross-device
/// sync.
///
/// This app's own local storage format is unchanged -- only the
/// GitHub-synced wire format and the cross-device merge algorithm now go
/// through `crdt_sync`'s `Record`/`Log`/`Hlc` primitives, the same ones the
/// PC (`diet_guard/_sync_merge.py`) and every other kuhy app that syncs
/// this way uses.
///
/// Each [FoodEntry] maps to one [Record] with a single opaque `body` field
/// holding [FoodEntry.toSyncJson] (already excludes `imagePath` and `hmac`
/// -- neither belongs in the synced Record: `imagePath` is phone-local and
/// reattached by `sync_service.dart` as a separate post-merge step; `hmac`
/// is never computed here, since the phone never holds the shared key).
/// Entries are immutable after creation (only `deleted` ever changes
/// post-write), so there is no benefit to crdt_sync's per-field LWW
/// granularity here -- the whole body shares one derived [Hlc].
///
/// Backward compatible with devices not yet migrated: [parseRemoteLog]
/// tries the new Record-based wire format first and falls back to the old
/// plain-DayLog format, converting old-format entries through the same
/// adapter used for the local log.
///
/// The budget adapters at the bottom of this file ([budgetToLog] etc.)
/// follow the same Record/Log shape, but a budget record is edited
/// repeatedly (not immutable-after-creation like a food-log entry), so its
/// [Hlc] is derived from a `t` edit timestamp
/// (`AppSettingsService.dailyKcalGoalUpdatedAt`) rather than a birth time
/// that never changes -- mirrors `diet_guard/_sync_merge.py`'s budget
/// adapters field-for-field.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';

const _syncDeviceId = 'phone';

/// Derives a deterministic [Hlc] for [entry] from its own `time` field.
///
/// The same entry always yields the same Hlc regardless of when this runs
/// -- entries are immutable after creation, so there's no real "now" to
/// stamp, just the birth-time already recorded on the entry itself.
/// Malformed/missing `time` still yields a valid (if early-sorting) Hlc
/// rather than throwing -- this only affects tie-breaking between
/// otherwise-identical copies of the same id, never whether the entry
/// survives a merge.
Hlc entryHlc(FoodEntry entry) {
  final wallTimeMs = DateTime.tryParse(entry.time)?.millisecondsSinceEpoch ?? 0;
  return Hlc.newTick(_syncDeviceId, wallTimeMsOverride: wallTimeMs);
}

/// Deterministic id for a pre-`id` legacy entry, from `(time, desc)`.
///
/// Two devices holding the same legacy entry independently derive the same
/// id without communicating, so they merge as one record instead of two --
/// the same guarantee the old `(time, desc)` dedup key gave, just expressed
/// as a real id going forward.
String legacyEntryId(FoodEntry entry) {
  final key = '${entry.time}|${entry.desc}';
  final digest = sha256.convert(utf8.encode(key)).toString().substring(0, 32);
  return 'legacy-$digest';
}

/// Converts one [FoodEntry] to a crdt_sync [Record].
Record entryToRecord(FoodEntry entry) {
  final id = (entry.id != null && entry.id!.isNotEmpty)
      ? entry.id!
      : legacyEntryId(entry);
  final hlc = entryHlc(entry);
  final body = entry.toSyncJson()
    ..remove('id')
    ..remove('deleted');
  return Record(
    id: id,
    fields: {'body': (body, hlc)},
    deleted: entry.deleted,
    deletedHlc: entry.deleted ? hlc : null,
  );
}

/// Converts one crdt_sync [Record] back to a [FoodEntry].
FoodEntry recordToEntry(Record record) {
  final bodyValue = record.fields['body']?.$1;
  final body = bodyValue is Map
      ? bodyValue.cast<String, dynamic>()
      : <String, dynamic>{};
  return FoodEntry.fromJson({
    ...body,
    'id': record.id,
    'deleted': record.deleted,
  });
}

/// Converts a full local/remote [DayLog] into a crdt_sync [Log].
Log dayLogToLog(DayLog daylog) {
  final log = <String, Record>{};
  for (final entries in daylog.values) {
    for (final entry in entries) {
      final record = entryToRecord(entry);
      log[record.id] = record;
    }
  }
  return log;
}

/// Converts a merged crdt_sync [Log] back into [DayLog] shape.
///
/// Each entry is re-bucketed under its own `time`'s date rather than
/// whatever date key it might have arrived under, and each day's entries
/// are sorted oldest-first -- matching the existing on-disk convention.
DayLog logToDayLog(Log log) {
  final daylog = <String, List<FoodEntry>>{};
  for (final record in log.values) {
    final entry = recordToEntry(record);
    final dateKey = entry.time.length >= 10
        ? entry.time.substring(0, 10)
        : entry.time;
    daylog.putIfAbsent(dateKey, () => []).add(entry);
  }
  for (final entries in daylog.values) {
    entries.sort((a, b) => a.time.compareTo(b.time));
  }
  return daylog;
}

/// Returns true if [raw] is shaped like a crdt_sync Record-keyed Log.
///
/// An empty object is ambiguous but harmless either way (no entries to
/// convert), so it's treated as new format to skip the old-format
/// conversion pass for nothing.
bool _looksLikeNewFormat(Map<String, dynamic> raw) => raw.values.every(
  (value) =>
      value is Map<String, dynamic> &&
      value.containsKey('fields') &&
      value.containsKey('id'),
);

/// Parses one device's pushed log text into a crdt_sync [Log].
///
/// Tries the new Record-based wire format first; falls back to the old
/// plain-DayLog format (today's on-the-wire shape) for devices not yet
/// migrated onto crdt_sync, converting their entries through the same
/// adapter the local log uses. Throwing [FormatException] or [TypeError] is
/// treated as unparsable by the caller (`sync_service.dart`'s `syncLog`
/// `decode` callback), mirroring `_sync._pull_remote_logs`'s tolerance for a
/// corrupt/truncated push.
Log parseRemoteLog(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map) {
    throw const FormatException(
      'top-level sync payload is not a JSON object',
    );
  }
  final rawMap = raw.cast<String, dynamic>();
  if (_looksLikeNewFormat(rawMap)) {
    return rawMap.map(
      (id, data) => MapEntry(id, Record.fromJson(data as Map<String, dynamic>)),
    );
  }

  final daylog = <String, List<FoodEntry>>{};
  for (final mapEntry in rawMap.entries) {
    final entries = mapEntry.value;
    if (entries is! List) {
      throw FormatException(
        'day ${mapEntry.key} is not a JSON array',
      );
    }
    daylog[mapEntry.key] = entries
        .whereType<Map<String, dynamic>>()
        .map((m) => FoodEntry.fromJson(m.cast<String, dynamic>()))
        .toList();
  }
  return dayLogToLog(daylog);
}

/// Serializes a merged [Log] for push, in the new Record-based wire format.
String encodeLogForPush(Log log) {
  final encoded = <String, dynamic>{
    for (final entry in log.entries) entry.key: entry.value.toJson(),
  };
  return jsonEncode(encoded);
}

/// Stable id: exactly one budget record per device-pushed `budget.json`.
const budgetRecordId = 'budget';

/// Derives a deterministic [Hlc] for a raw budget record from its `t` field.
///
/// Mirrors [entryHlc]'s determinism -- the same unedited record always
/// yields the same Hlc, so re-syncing an unchanged budget is a no-op -- but
/// reads `t` (bumped on every explicit edit) rather than a fixed birth
/// time, since a budget can be edited repeatedly and the *edit* time is
/// what last-writer-wins must compare.
Hlc budgetHlc(Map<String, dynamic> record) {
  final wallTimeMs =
      DateTime.tryParse(
        record['t'] as String? ?? '',
      )?.toUtc().millisecondsSinceEpoch ??
      0;
  return Hlc.newTick(_syncDeviceId, wallTimeMsOverride: wallTimeMs);
}

/// Converts a raw local/remote budget record into a single-record [Log].
///
/// Returns an empty [Log] when [record] is null (this device has never
/// explicitly set a budget), so it contributes nothing to the merge rather
/// than clobbering another device's real value with the unset default.
Log budgetToLog(Map<String, dynamic>? record) {
  if (record == null) return {};
  final hlc = budgetHlc(record);
  final value = Map<String, dynamic>.from(record)..remove('t');
  return {
    budgetRecordId: Record(id: budgetRecordId, fields: {'value': (value, hlc)}),
  };
}

/// Converts a merged budget [Log] back into a raw budget record.
///
/// Returns null when the log has no budget record at all (neither device
/// has ever set one yet) -- callers treat that as "nothing to apply
/// locally", not an error.
Map<String, dynamic>? logToBudget(Log log) {
  final record = log[budgetRecordId];
  if (record == null) return null;
  final field = record.fields['value'];
  final value = field?.$1;
  final result = value is Map
      ? Map<String, dynamic>.from(value.cast<String, dynamic>())
      : <String, dynamic>{};
  final hlc = field?.$2;
  if (hlc != null) {
    result['t'] = DateTime.fromMillisecondsSinceEpoch(
      hlc.wallTimeMs,
      isUtc: true,
    ).toLocal().toIso8601String();
  }
  return result;
}

/// Parses one device's pushed `budget.json` text into a crdt_sync [Log].
///
/// Throwing [FormatException] or [TypeError] is treated as unparsable by
/// the caller (`syncLog`'s `decode` callback), matching [parseRemoteLog]'s
/// tolerance for a corrupt/truncated push. There is no legacy plain-format
/// fallback here -- `budget.json` is a brand-new sync payload.
Log parseRemoteBudget(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map) {
    throw const FormatException(
      'top-level budget payload is not a JSON object',
    );
  }
  final rawMap = raw.cast<String, dynamic>();
  return rawMap.map(
    (id, data) => MapEntry(id, Record.fromJson(data as Map<String, dynamic>)),
  );
}

/// Serializes a merged budget [Log] for push.
String encodeBudgetForPush(Log log) {
  final encoded = <String, dynamic>{
    for (final entry in log.entries) entry.key: entry.value.toJson(),
  };
  return jsonEncode(encoded);
}
