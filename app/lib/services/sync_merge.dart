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
/// holding [FoodEntry.toSyncJson] (which excludes `hmac`: it is never
/// computed here, since the phone never holds the shared key, and the PC
/// re-signs every entry on merge regardless of origin).
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
import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/github_client_factory.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';

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
  return Hlc.newTick(syncDeviceId, wallTimeMsOverride: wallTimeMs);
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

/// Converts the log-derived food bank into a crdt_sync [Log].
///
/// The bank is *derived* -- both devices replay the same synced log and
/// compute the same records -- so this exists to make them agree
/// **immediately** rather than only after each has replayed.
///
/// The clock is the record's own `count`, not a wall time, so
/// last-writer-wins means *max-count-wins*: the device that has seen more of
/// the log has the higher count, and re-merging is idempotent because the
/// count does not move unless the log did. Mirrors
/// `_sync_merge.food_bank_to_log`.
Log foodBankToLog(Map<String, FoodBankRecord> bank) {
  final log = <String, Record>{};
  for (final mapEntry in bank.entries) {
    log[mapEntry.key] = Record(
      id: mapEntry.key,
      fields: {
        'body': (
          mapEntry.value.toJson(),
          Hlc.newTick(
            syncDeviceId,
            wallTimeMsOverride: mapEntry.value.count.toInt(),
          ),
        ),
      },
    );
  }
  return log;
}

/// Converts a merged food-bank [Log] back into bank shape.
Map<String, FoodBankRecord> logToFoodBank(Log log) {
  final bank = <String, FoodBankRecord>{};
  for (final mapEntry in log.entries) {
    if (mapEntry.value.deleted) continue;
    final body = mapEntry.value.fields['body']?.$1;
    if (body is! Map) continue;
    bank[mapEntry.key] = FoodBankRecord.fromJson(
      Map<String, dynamic>.from(body.cast<String, dynamic>()),
    );
  }
  return bank;
}

/// Parses one device's pushed `food_bank.json` into a crdt_sync [Log].
Log parseRemoteFoodBank(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map) {
    throw const FormatException(
      'top-level food-bank payload is not a JSON object',
    );
  }
  return raw.cast<String, dynamic>().map(
    (id, data) => MapEntry(id, Record.fromJson(data as Map<String, dynamic>)),
  );
}

/// Serializes a merged food-bank [Log] for push.
String encodeFoodBankForPush(Log log) => jsonEncode({
  for (final entry in log.entries) entry.key: entry.value.toJson(),
});

/// Converts the hand-curated food bank into a crdt_sync [Log].
///
/// One record per normalized food name, carrying the whole bank record as an
/// opaque `body` -- the same shape food-log entries use. Unlike an entry a
/// curated food is editable, so its [Hlc] comes from the record's own
/// `editedAt` stamp rather than a fixed birth time. Mirrors
/// `_sync_merge.manual_bank_to_log`.
Log manualBankToLog(Map<String, FoodBankRecord> bank) {
  final log = <String, Record>{};
  for (final mapEntry in bank.entries) {
    final wallTimeMs =
        DateTime.tryParse(
          mapEntry.value.editedAt ?? '',
        )?.toUtc().millisecondsSinceEpoch ??
        0;
    final body = Map<String, dynamic>.from(mapEntry.value.toJson())
      ..remove('t');
    log[mapEntry.key] = Record(
      id: mapEntry.key,
      fields: {
        'body': (
          body,
          Hlc.newTick(syncDeviceId, wallTimeMsOverride: wallTimeMs),
        ),
      },
    );
  }
  return log;
}

/// Converts a merged curated-bank [Log] back into bank shape.
///
/// Each record's `editedAt` is reconstructed from its field [Hlc], so the
/// stored stamp and the clock the merge compared can never drift apart.
/// Mirrors `_sync_merge.log_to_manual_bank`.
Map<String, FoodBankRecord> logToManualBank(Log log) {
  final bank = <String, FoodBankRecord>{};
  for (final mapEntry in log.entries) {
    if (mapEntry.value.deleted) continue;
    final field = mapEntry.value.fields['body'];
    final body = field?.$1;
    if (body is! Map) continue;
    final json = Map<String, dynamic>.from(body.cast<String, dynamic>());
    final hlc = field?.$2;
    if (hlc != null) {
      json['t'] = DateTime.fromMillisecondsSinceEpoch(
        hlc.wallTimeMs,
        isUtc: true,
      ).toLocal().toIso8601String();
    }
    bank[mapEntry.key] = FoodBankRecord.fromJson(json);
  }
  return bank;
}

/// Parses one device's pushed curated-bank text into a crdt_sync [Log].
Log parseRemoteManualBank(String text) {
  final raw = jsonDecode(text);
  if (raw is! Map) {
    throw const FormatException(
      'top-level curated-bank payload is not a JSON object',
    );
  }
  return raw.cast<String, dynamic>().map(
    (id, data) => MapEntry(id, Record.fromJson(data as Map<String, dynamic>)),
  );
}

/// Serializes a merged curated-bank [Log] for push.
String encodeManualBankForPush(Log log) => jsonEncode({
  for (final entry in log.entries) entry.key: entry.value.toJson(),
});

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
  return Hlc.newTick(syncDeviceId, wallTimeMsOverride: wallTimeMs);
}

/// Field-name prefix for the effective-from budget history, one field per
/// date. A separate *field* rather than a separate document, because
/// `mergeRecord` unions field names -- see [budgetToLog].
const budgetHistoryFieldPrefix = 'hist:';

/// Derives a deterministic [Hlc] for one history entry from its edit time.
///
/// Same trick as [budgetHlc]: identical inputs always yield the same clock,
/// so re-syncing unchanged history is a no-op. Two devices that seed the
/// history independently derive the same wall time and the same value and
/// differ only in node id, so whichever side wins the field-level LWW, the
/// value is identical and the merge converges in one round.
Hlc historyHlc(BudgetEntry entry) {
  final wallTimeMs =
      DateTime.tryParse(entry.editedAt)?.toUtc().millisecondsSinceEpoch ?? 0;
  return Hlc.newTick(syncDeviceId, wallTimeMsOverride: wallTimeMs);
}

/// Converts a raw local budget record plus its history into a [Log].
///
/// Returns an empty [Log] when [record] is null (this device has never
/// explicitly set a budget), so it contributes nothing to the merge rather
/// than clobbering another device's real value with the unset default.
///
/// The history rides along as one `hist:<YYYY-MM-DD>` field per entry on the
/// *same* record. crdt_sync's `mergeRecord` is per-field LWW over the union
/// of field names, so a device that predates the history neither clobbers
/// those fields nor blocks them: it merges them in from the remote and
/// pushes them straight back out (both sides push the *merged* log). That is
/// what makes this safe to roll out without a coordinated release.
///
/// `w` (body weight) is stripped from `value` for the same reason the
/// history is not stored there: inside the shared map it was collateral
/// damage of whole-map LWW, since this device rebuilds that map without it.
/// Python carries it as its own `weight` field instead, and this device
/// relays that field untouched through the merged log even though it has no
/// weight of its own to contribute -- so both devices still see one value.
Log budgetToLog(
  Map<String, dynamic>? record, [
  List<BudgetEntry> entries = const [],
]) {
  if (record == null) return {};
  final hlc = budgetHlc(record);
  final value = Map<String, dynamic>.from(record)
    ..remove('t')
    ..remove('w');
  final fields = <String, (dynamic, Hlc)>{'value': (value, hlc)};
  for (final entry in entries) {
    fields['$budgetHistoryFieldPrefix${entry.effectiveFrom}'] = (
      entry.kcal,
      historyHlc(entry),
    );
  }
  return {budgetRecordId: Record(id: budgetRecordId, fields: fields)};
}

/// Extracts the effective-from history from a merged budget [Log].
///
/// Each entry's `editedAt` is reconstructed from its field Hlc rather than
/// carried separately, so the stored timestamp and the clock the merge
/// compared can never drift apart.
List<BudgetEntry> logToHistory(Log log) {
  final record = log[budgetRecordId];
  if (record == null) return const [];
  final entries = <BudgetEntry>[];
  for (final field in record.fields.entries) {
    if (!field.key.startsWith(budgetHistoryFieldPrefix)) continue;
    final kcal = field.value.$1;
    if (kcal is! int) continue;
    entries.add(
      BudgetEntry(
        effectiveFrom: field.key.substring(budgetHistoryFieldPrefix.length),
        kcal: kcal,
        editedAt: DateTime.fromMillisecondsSinceEpoch(
          field.value.$2.wallTimeMs,
          isUtc: true,
        ).toLocal().toIso8601String(),
      ),
    );
  }
  entries.sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));
  return entries;
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
