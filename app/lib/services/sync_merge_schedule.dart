/// Meal-schedule history as extra fields on the shared `budget` record.
///
/// Split out of `sync_merge_budget.dart` to keep both under the repo's
/// 250-line limit; the two halves are otherwise the same idea and share one
/// record.
///
/// The schedule rides as one `sched:<YYYY-MM-DD>` field per history entry,
/// exactly like the budget's `hist:` fields. `mergeRecord` is per-field
/// last-writer-wins over the *union* of field names, and both devices push
/// the *merged* record rather than their own, so a device that predates meal
/// schedules neither clobbers those fields nor blocks them -- it relays them
/// untouched. That is what makes this shippable without a coordinated
/// release.
///
/// KEEP IN SYNC WITH `diet_guard/sync_merge/_schedule.py`.
library;

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/services/meal_schedule_history.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';

/// The shared record these fields live on. Declared here rather than imported
/// from `sync_merge_budget.dart` so the two modules do not import each other;
/// `_schedule.py` declares its own copy for the same reason.
const _budgetRecordId = 'budget';

/// Field-name prefix for the effective-from meal-schedule history.
const scheduleFieldPrefix = 'sched:';

/// Derives a deterministic [Hlc] for one schedule entry from its edit time.
///
/// Identical inputs always yield the same clock, so re-syncing an unchanged
/// history is a no-op. Derived from the *parsed* timestamp rather than the
/// raw string, so the two languages agree even though they format the epoch
/// fallback differently.
Hlc scheduleHlc(ScheduleEntry entry) {
  final wallTimeMs =
      DateTime.tryParse(entry.editedAt)?.toUtc().millisecondsSinceEpoch ?? 0;
  return Hlc.newTick(currentSyncDeviceId, wallTimeMsOverride: wallTimeMs);
}

/// Returns the `sched:` fields contributed by [entries].
///
/// Empty when this device has no history, so a device that has never edited
/// a schedule contributes nothing to the merge rather than pushing the unset
/// default over a peer's real value.
Map<String, (dynamic, Hlc)> scheduleFields(List<ScheduleEntry> entries) => {
  for (final entry in entries)
    '$scheduleFieldPrefix${entry.effectiveFrom}': (
      {
        'f': entry.schedule.first,
        'l': entry.schedule.last,
        'n': entry.schedule.count,
      },
      scheduleHlc(entry),
    ),
};

/// Extracts the meal-schedule history from a merged budget [Log].
///
/// Each entry's `editedAt` is reconstructed from its field Hlc rather than
/// carried separately, so the stored timestamp and the clock the merge
/// compared can never drift apart. Malformed values are skipped, so one bad
/// field from a peer cannot take out the whole history.
List<ScheduleEntry> logToScheduleHistory(Log log) {
  final record = log[_budgetRecordId];
  if (record == null) return const [];
  final entries = <ScheduleEntry>[];
  for (final field in record.fields.entries) {
    if (!field.key.startsWith(scheduleFieldPrefix)) continue;
    final value = field.value.$1;
    if (value is! Map) continue;
    final first = value['f'];
    final last = value['l'];
    final count = value['n'];
    if (first is! int || last is! int || count is! int) continue;
    entries.add(
      ScheduleEntry(
        effectiveFrom: field.key.substring(scheduleFieldPrefix.length),
        // Normalised on the way in, so a peer running a future version with a
        // wider range cannot hand us a schedule we would derive slots
        // differently from.
        schedule: MealSchedule(
          first: first,
          last: last,
          count: count,
        ).normalized(),
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
