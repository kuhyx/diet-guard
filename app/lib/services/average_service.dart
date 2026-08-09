/// Weekly and monthly average intake, and how that average met the budget.
///
/// PERIOD AVERAGE SPEC (keep in sync with `diet_guard/_averages.py`):
///
/// * the average is over **logged days only** -- `sum(kcal) / loggedDays`. A
///   day you forgot to log is not a zero-calorie day, and counting it as one
///   would make every gap in the log read as "well under budget", which is the
///   exact opposite of the truth. `loggedDays`/`elapsedDays` travel with the
///   average so a caller can show how much of the period it covers.
/// * the yardstick is the **mean of the per-day budgets over those same logged
///   days**, resolved through a [BudgetSchedule] -- never today's budget.
///   Comparing a past week against a budget lowered yesterday would
///   retroactively reclassify it, which is what `budget_schedule.dart` exists
///   to prevent.
/// * bands reuse the calendar's own over-budget boundary
///   ([kOverBudgetYellowCeiling]), so a period and its days can never disagree
///   about what "over" means:
///
///   - `under`:        `avgKcal <= avgBudget`
///   - `slightlyOver`: `avgBudget < avgKcal <= avgBudget * ceiling`
///   - `veryOver`:     `avgKcal > avgBudget * ceiling`
///
/// * **today is excluded.** A period ending at "now" mixes complete days with
///   one that is three hours old, and a half-logged today drags the mean far
///   enough to flip the band. Every period ends at [lastCompleteDay] --
///   yesterday -- so "this week" means "this week so far, in finished days". A
///   period with no finished days yet (Monday, or the 1st) reports
///   `elapsedDays == 0` and a null average rather than a flattering fake one.
/// * weeks are **ISO weeks, Monday through Sunday**; months are calendar
///   months.
///
/// Every function here is a pure function of its explicit `log`/`schedule`/
/// `today` arguments and never reaches into on-disk state.
library;

import 'package:diet_guard_app/models/period_average.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/day_status_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';

/// Classifies [avgKcal] against [avgBudget].
AverageBand bandFor(double avgKcal, double avgBudget) {
  if (avgKcal <= avgBudget) return AverageBand.under;
  if (avgKcal <= avgBudget * kOverBudgetYellowCeiling) {
    return AverageBand.slightlyOver;
  }
  return AverageBand.veryOver;
}

/// Returns the last day whose log is finished: the day before [today].
DateTime lastCompleteDay(DateTime today) => _addDays(today, -1);

/// Returns the Monday and Sunday of the ISO week containing [day].
(DateTime, DateTime) weekBounds(DateTime day) {
  final monday = _addDays(day, DateTime.monday - day.weekday);
  return (monday, _addDays(monday, 6));
}

/// Returns the first and last dates of [day]'s calendar month.
(DateTime, DateTime) monthBounds(DateTime day) => (
  DateTime(day.year, day.month),
  // Day 0 of the *next* month is the last day of this one, resolved by
  // DateTime's constructor rather than by subtracting 24 hours.
  DateTime(day.year, day.month + 1, 0),
);

/// Returns the first of the month [months] before [day]'s month.
DateTime shiftMonths(DateTime day, int months) =>
    DateTime(day.year, day.month - months);

/// Averages [log]'s intake over `[start, end]` and classifies it.
///
/// An [end] before [start] is an empty period, not an error.
PeriodAverage periodAverage(
  DayLog log, {
  required BudgetSchedule schedule,
  required DateTime start,
  required DateTime end,
}) {
  final from = _dateOnly(start);
  final to = _dateOnly(end);
  var totalKcal = 0.0;
  var totalBudget = 0;
  var loggedDays = 0;
  var elapsedDays = 0;
  for (var day = from; !day.isAfter(to); day = _addDays(day, 1)) {
    elapsedDays++;
    final key = dateKey(day);
    final entries = (log[key] ?? const []).where((e) => !e.deleted);
    if (entries.isEmpty) continue;
    loggedDays++;
    totalKcal += sumKcal(entries);
    totalBudget += schedule.forDay(key);
  }
  if (loggedDays == 0) {
    return PeriodAverage(
      start: dateKey(from),
      end: dateKey(to),
      loggedDays: 0,
      elapsedDays: elapsedDays,
      avgKcal: null,
      avgBudget: null,
      band: null,
    );
  }
  final avgKcal = totalKcal / loggedDays;
  final avgBudget = totalBudget / loggedDays;
  return PeriodAverage(
    start: dateKey(from),
    end: dateKey(to),
    loggedDays: loggedDays,
    elapsedDays: elapsedDays,
    avgKcal: avgKcal,
    avgBudget: avgBudget,
    band: bandFor(avgKcal, avgBudget),
  );
}

/// Returns the average for an ISO week, [weeksAgo] weeks back.
///
/// [weeksAgo] 0 is the current week through yesterday, 1 the previous complete
/// week, and so on.
PeriodAverage weeklyAverage(
  DayLog log, {
  required BudgetSchedule schedule,
  int weeksAgo = 0,
  DateTime? today,
}) {
  final ref = _dateOnly(today ?? DateTime.now());
  final anchor = _addDays(ref, -DateTime.daysPerWeek * weeksAgo);
  return _capped(log, schedule, weekBounds(anchor), ref);
}

/// Returns the average for a calendar month, [monthsAgo] months back.
PeriodAverage monthlyAverage(
  DayLog log, {
  required BudgetSchedule schedule,
  int monthsAgo = 0,
  DateTime? today,
}) {
  final ref = _dateOnly(today ?? DateTime.now());
  return _capped(log, schedule, monthBounds(shiftMonths(ref, monthsAgo)), ref);
}

/// Averages [bounds], truncated so it never includes [ref] itself.
///
/// The single place the "today is excluded" rule is applied, so a caller
/// cannot construct a period that half-counts an unfinished day.
PeriodAverage _capped(
  DayLog log,
  BudgetSchedule schedule,
  (DateTime, DateTime) bounds,
  DateTime ref,
) {
  final (start, end) = bounds;
  final cap = lastCompleteDay(ref);
  return periodAverage(
    log,
    schedule: schedule,
    start: start,
    end: end.isBefore(cap) ? end : cap,
  );
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Returns midnight [days] calendar days from [d], safely across DST.
///
/// Deliberately NOT `d.add(Duration(days: days))`: a [Duration] is an absolute
/// span, so on a local [DateTime] it moves by 23 or 25 hours across a DST
/// boundary and lands on the wrong wall-clock day.  In Europe/Warsaw that made
/// `lastCompleteDay(2026-03-30)` return the day *before* yesterday, put the
/// `weeksAgo` anchor in the wrong ISO week, and silently drop the last day of
/// any period spanning spring-forward -- so the phone and the PC disagreed
/// about the same log for two weeks a year.  Passing out-of-range components
/// to the constructor normalizes on the *calendar* instead, which is what
/// Python's `timedelta` on a `date` already does.
DateTime _addDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days);

/// Formats [d] as a `YYYY-MM-DD` log key.
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
