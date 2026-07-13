/// Per-day budget-adherence status, streaks, and year-to-date tallies.
///
/// DAY STATUS SPEC (keep in sync with `diet_guard/_daystatus.py`):
///
/// * green: `total_kcal <= budget`
/// * yellow: `budget < total_kcal <= budget * kOverBudgetYellowCeiling`
/// * red: `total_kcal > budget * kOverBudgetYellowCeiling`
/// * notLogged: the day is absent from the log entirely (no valid,
///   non-tombstoned entries).
/// * ordering, worst to best: notLogged > red > yellow > green.
/// * the logging streak breaks on a not-logged day.
/// * the adherence streak breaks on a red or a not-logged day; yellow and
///   green both keep it alive.
///
/// Every function here is a pure function of an explicit `log`/`statusMap`
/// argument (never reaching into on-disk state itself), so the boundary
/// matrix above is trivially testable with synthetic data.
library;

import 'package:diet_guard_app/models/day_status.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';

/// The multiplier defining the top of the "yellow" band above budget: a 20%
/// margin, mirroring `diet_guard._constants.BUDGET_WARN_FRACTION` (0.80)'s
/// 20% margin below 100% on the "approaching limit" side, so the two bands
/// are symmetric around the budget line.
const double kOverBudgetYellowCeiling = 1.20;

const Set<DayStatus> _loggedStatuses = {
  DayStatus.green,
  DayStatus.yellow,
  DayStatus.red,
};

const Set<DayStatus> _adherentStatuses = {DayStatus.green, DayStatus.yellow};

/// Returns the summed kcal across [entries].
///
/// Shared by [dayTotalKcal] and `history_screen.dart`'s day-header total, so
/// the "sum a day's entries" logic exists in exactly one place regardless of
/// whether the caller already has a day's entries grouped or is looking one
/// up by date key.
double sumKcal(Iterable<FoodEntry> entries) {
  var total = 0.0;
  for (final entry in entries) {
    total += entry.kcal;
  }
  return total;
}

/// Returns [log]'s entries for [day] with tombstoned (deleted) ones
/// removed -- `readLog()` returns the raw log including tombstones, so
/// every consumer that classifies a day (rather than just displaying an
/// already-filtered list) must drop them here first.
Iterable<FoodEntry> _validEntriesForDay(DayLog log, String day) =>
    (log[day] ?? const []).where((entry) => !entry.deleted);

/// Returns the summed kcal for one `YYYY-MM-DD` key in [log], excluding
/// tombstoned entries.
double dayTotalKcal(DayLog log, String day) =>
    sumKcal(_validEntriesForDay(log, day));

/// Classifies one day's budget adherence.
///
/// A day with no valid, non-tombstoned entries is [DayStatus.notLogged] --
/// a day whose only entries were later deleted must not read as green at
/// zero kcal.
DayStatus dayStatus(DayLog log, String day, int budget) {
  final entries = _validEntriesForDay(log, day).toList();
  if (entries.isEmpty) return DayStatus.notLogged;
  final total = sumKcal(entries);
  if (total <= budget) return DayStatus.green;
  if (total <= budget * kOverBudgetYellowCeiling) return DayStatus.yellow;
  return DayStatus.red;
}

/// Returns a [DayStatus] for every date key present in [log].
///
/// Days with no log entries are simply absent from the result; a caller
/// rendering a full calendar treats a missing key as [DayStatus.notLogged].
Map<String, DayStatus> statusMap(DayLog log, {required int budget}) {
  return {for (final day in log.keys) day: dayStatus(log, day, budget)};
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _dateKey(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

int _streak(
  Map<String, DayStatus> statusMap,
  Set<DayStatus> keeps, {
  DateTime? today,
}) {
  var day = _dateOnly(today ?? DateTime.now());
  if (statusMap[_dateKey(day)] == null) {
    day = day.subtract(const Duration(days: 1));
  }
  var count = 0;
  while (keeps.contains(statusMap[_dateKey(day)])) {
    count++;
    day = day.subtract(const Duration(days: 1));
  }
  return count;
}

/// Returns the consecutive-day logging streak ending at [today].
///
/// A [today] absent from [statusMap] (not yet logged) is skipped rather
/// than treated as a break, so the streak does not appear broken every
/// morning before the user has eaten; counting resumes from yesterday in
/// that case. Any other day missing from [statusMap] ends the streak.
int loggingStreak(Map<String, DayStatus> statusMap, {DateTime? today}) =>
    _streak(statusMap, _loggedStatuses, today: today);

/// Returns the consecutive-day budget-adherence streak ending at [today].
///
/// Breaks on a red or not-logged day; green and yellow days both keep it
/// alive ("not too aggressively crossed").
int adherenceStreak(Map<String, DayStatus> statusMap, {DateTime? today}) =>
    _streak(statusMap, _adherentStatuses, today: today);

int _dayOfYear(DateTime d) {
  final start = DateTime.utc(d.year);
  final day = DateTime.utc(d.year, d.month, d.day);
  return day.difference(start).inDays + 1;
}

/// Returns this year's logged/elapsed/adherent day counts.
///
/// [today] is the reference date; defaults to the real current date.
/// [elapsedDays] is inclusive of [today].
YtdTally yearToDateTally(Map<String, DayStatus> statusMap, {DateTime? today}) {
  final ref = _dateOnly(today ?? DateTime.now());
  final elapsedDays = _dayOfYear(ref);
  var loggedDays = 0;
  var adherentDays = 0;
  for (final mapEntry in statusMap.entries) {
    if (mapEntry.value == DayStatus.notLogged) continue;
    final day = DateTime.parse(mapEntry.key);
    if (day.year != ref.year || day.isAfter(ref)) continue;
    loggedDays++;
    if (_adherentStatuses.contains(mapEntry.value)) adherentDays++;
  }
  return YtdTally(
    loggedDays: loggedDays,
    elapsedDays: elapsedDays,
    adherentDays: adherentDays,
  );
}
