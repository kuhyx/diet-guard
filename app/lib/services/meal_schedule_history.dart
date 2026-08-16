/// Forward-only history of the user's meal schedule.
///
/// The pure half: parsing, encoding, and resolving which schedule applied on a
/// given day. Persistence lives in `meal_schedule_service.dart`.
///
/// Judging a past day must use the schedule that applied on that day --
/// otherwise switching from four meals to five would retroactively mark every
/// earlier day as having missed a checkpoint.
///
/// KEEP IN SYNC WITH `diet_guard/_meal_schedule_store.py`.
library;

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:flutter/foundation.dart';

/// The effective-from date a seed uses, so the pre-history schedule covers
/// every day that was ever logged. Any real date is >= this.
const String kScheduleEpochDay = '1970-01-01';

const String _epochIso = '1970-01-01T00:00:00.000Z';

/// One meal schedule and the date it started applying.
@immutable
class ScheduleEntry {
  /// Creates a [ScheduleEntry].
  const ScheduleEntry({
    required this.effectiveFrom,
    required this.schedule,
    required this.editedAt,
  });

  /// `YYYY-MM-DD`; the first day this schedule applies to.
  final String effectiveFrom;

  /// The eating window and meal count from that day onward.
  final MealSchedule schedule;

  /// ISO-8601 timestamp of the edit that created this entry.
  final String editedAt;

  @override
  bool operator ==(Object other) =>
      other is ScheduleEntry &&
      other.effectiveFrom == effectiveFrom &&
      other.schedule == schedule &&
      other.editedAt == editedAt;

  @override
  int get hashCode => Object.hash(effectiveFrom, schedule, editedAt);
}

/// Returns the wire/disk form of one entry's value.
Map<String, Object?> scheduleEntryToJson(ScheduleEntry entry) => {
  'f': entry.schedule.first,
  'l': entry.schedule.last,
  'n': entry.schedule.count,
  't': entry.editedAt,
};

/// Returns an entry parsed from its stored value, or null if unusable.
///
/// Never throws: a malformed entry is skipped so one bad field from a peer
/// cannot take out the whole history.
ScheduleEntry? scheduleEntryFromJson(String effectiveFrom, Object? raw) {
  if (raw is! Map) return null;
  final first = raw['f'];
  final last = raw['l'];
  final count = raw['n'];
  if (first is! int || last is! int || count is! int) return null;
  final editedAt = raw['t'];
  return ScheduleEntry(
    effectiveFrom: effectiveFrom,
    // Normalising on the way in means a peer running a future version with a
    // wider range cannot hand us a schedule we would derive differently.
    schedule: MealSchedule(
      first: first,
      last: last,
      count: count,
    ).normalized(),
    editedAt: editedAt is String ? editedAt : _epochIso,
  );
}

/// A forward-only list of schedule entries, ascending by date.
@immutable
class MealScheduleHistory {
  /// Creates a history from [entries], sorting them ascending.
  MealScheduleHistory(List<ScheduleEntry> entries)
    : entries = List.unmodifiable(_sorted(entries));

  /// A history with no entries; every day resolves to [kDefaultSchedule].
  static final MealScheduleHistory empty = MealScheduleHistory(const []);

  /// The entries, ascending by [ScheduleEntry.effectiveFrom].
  final List<ScheduleEntry> entries;

  /// Returns the schedule in force on [day] (`YYYY-MM-DD`).
  ///
  /// The newest entry effective on or before [day], or the default when the
  /// history says nothing about that day.
  MealSchedule forDay(String day) {
    var result = kDefaultSchedule;
    for (final entry in entries) {
      if (entry.effectiveFrom.compareTo(day) <= 0) {
        result = entry.schedule;
      }
    }
    return result;
  }

  /// Returns this history with [schedule] effective from [when]'s date.
  ///
  /// Re-editing on the same day replaces that day's entry rather than
  /// stacking a second one.
  MealScheduleHistory upsert(MealSchedule schedule, {DateTime? when}) {
    final moment = when ?? DateTime.now();
    final day = _dayKey(moment);
    return MealScheduleHistory([
      ...entries.where((entry) => entry.effectiveFrom != day),
      ScheduleEntry(
        effectiveFrom: day,
        schedule: schedule.normalized(),
        editedAt: moment.toIso8601String(),
      ),
    ]);
  }

  /// Returns this history with the default schedule pinned to the epoch.
  ///
  /// Recording today's schedule without this would leave every *earlier* day
  /// with no applicable entry, and those days would then adopt whatever the
  /// user just chose -- exactly the retroactive reclassification the history
  /// exists to prevent. Callers must seed **before** recording today's value.
  MealScheduleHistory seedDefault() {
    if (entries.any((entry) => entry.effectiveFrom == kScheduleEpochDay)) {
      return this;
    }
    return MealScheduleHistory([
      const ScheduleEntry(
        effectiveFrom: kScheduleEpochDay,
        schedule: kDefaultSchedule,
        editedAt: _epochIso,
      ),
      ...entries,
    ]);
  }

  /// Parses a stored document into entries, ascending.
  ///
  /// Anything unreadable yields no entries, which callers treat as "fall back
  /// to the default schedule" -- the pre-feature behaviour.
  static List<ScheduleEntry> parse(Object? raw) {
    if (raw is! Map) return const [];
    final stored = raw['e'];
    if (stored is! Map) return const [];
    final parsed = <ScheduleEntry>[];
    for (final entry in stored.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final value = scheduleEntryFromJson(key, entry.value);
      if (value != null) parsed.add(value);
    }
    parsed.sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));
    return parsed;
  }

  /// Returns the on-disk document for [entries].
  static Map<String, Object?> encode(List<ScheduleEntry> entries) => {
    'v': 1,
    'e': {
      for (final entry in entries)
        entry.effectiveFrom: scheduleEntryToJson(entry),
    },
  };
}

List<ScheduleEntry> _sorted(List<ScheduleEntry> entries) =>
    List<ScheduleEntry>.of(entries)
      ..sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));

String _dayKey(DateTime moment) {
  final local = moment.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}
