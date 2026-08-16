/// Budget and budget-history <-> crdt_sync.Record adapters.
///
/// Split out of `sync_merge.dart` for file size; that file re-exports these
/// so existing importers keep working.
///
/// A budget record is edited repeatedly rather than immutable-after-creation
/// like a food-log entry, so its [Hlc] derives from a `t` edit timestamp
/// rather than a birth time that never changes. History rides along as
/// `hist:<YYYY-MM-DD>` fields on the same record, so a device predating the
/// feature relays them untouched. Mirrors `diet_guard/_sync_merge.py`.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/meal_schedule_history.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:diet_guard_app/services/sync_merge_schedule.dart';

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
  return Hlc.newTick(currentSyncDeviceId, wallTimeMsOverride: wallTimeMs);
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
  return Hlc.newTick(currentSyncDeviceId, wallTimeMsOverride: wallTimeMs);
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
  List<ScheduleEntry> scheduleEntries = const [],
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
  // The meal-schedule history rides the same record as its own `sched:`
  // fields; see `sync_merge_schedule.dart`.
  fields.addAll(scheduleFields(scheduleEntries));
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
