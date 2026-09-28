/// Weekly-average planner: what to eat on the rest of the week's days.
///
/// Port of `diet_guard/_week_plan.py`, gated by the shared
/// `tests/fixtures/body_calc.json`. The week is Monday-Sunday around
/// `today`. A day is known when the user typed a number for it, or when it is
/// already over and has meals in the log; every other day -- today included --
/// shares `(target x 7 - known) / remaining`. A past day with no log is
/// `unlogged` and planned like a remaining day (an unlogged day is not a
/// zero-kcal day). Informational only: it never touches the budget.
library;

import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/body_energy.dart';

/// Weekday labels, Monday first.
const List<String> weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// One day of the plan.
class DayPlan {
  /// Creates a day.
  const DayPlan({
    required this.day,
    required this.weekday,
    required this.kcal,
    required this.source,
  });

  /// `YYYY-MM-DD`.
  final String day;

  /// `Mon` .. `Sun`.
  final String weekday;

  /// What was eaten (known) or should be eaten (planned).
  final int kcal;

  /// `typed`, `logged`, `plan` or `unlogged`.
  final String source;
}

/// The whole week.
class WeekPlan {
  /// Creates a plan.
  const WeekPlan({
    required this.days,
    required this.targetAvg,
    required this.perRemaining,
    required this.weekAvg,
  });

  /// Monday .. Sunday.
  final List<DayPlan> days;

  /// The weekly average aimed for.
  final int targetAvg;

  /// kcal for each open day, or null when none remain.
  final int? perRemaining;

  /// The average the plan produces.
  final double weekAvg;

  /// Whether the remaining days would have to go under 1200 kcal.
  bool get belowFloor {
    final per = perRemaining;
    return per != null && per < minTargetKcal;
  }
}

String _key(DateTime day) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}'
      '-${two(day.day)}';
}

/// The Monday of [today]'s week, at local midnight.
DateTime weekStart(DateTime today) =>
    DateTime(today.year, today.month, today.day - (today.weekday - 1));

/// Plans the rest of [today]'s week.
///
/// [logged] maps `YYYY-MM-DD` to kcal eaten (only days before [today] are
/// used); [typed] maps weekday index (0 = Monday) to a typed kcal, which wins
/// over the log and may name any day.
WeekPlan planWeek(
  DateTime today,
  int targetAvg,
  Map<String, double> logged,
  Map<int, int> typed,
) {
  final monday = weekStart(today);
  final todayKey = _key(today);
  String dayKey(int index) =>
      _key(DateTime(monday.year, monday.month, monday.day + index));
  final known = <int, (int, String)>{};
  for (var index = 0; index < 7; index++) {
    final key = dayKey(index);
    final typedKcal = typed[index];
    final loggedKcal = logged[key];
    if (typedKcal != null) {
      known[index] = (typedKcal, 'typed');
    } else if (key.compareTo(todayKey) < 0 && loggedKcal != null) {
      known[index] = (halfUp(loggedKcal).toInt(), 'logged');
    }
  }
  final remaining = 7 - known.length;
  final eaten = known.values.fold<int>(0, (sum, day) => sum + day.$1);
  final per = remaining == 0
      ? null
      : halfUp((targetAvg * 7 - eaten) / remaining).toInt();
  final days = [
    for (var index = 0; index < 7; index++)
      DayPlan(
        day: dayKey(index),
        weekday: weekdays[index],
        kcal: known[index]?.$1 ?? per ?? 0,
        source:
            known[index]?.$2 ??
            (dayKey(index).compareTo(todayKey) < 0 ? 'unlogged' : 'plan'),
      ),
  ];
  return WeekPlan(
    days: days,
    targetAvg: targetAvg,
    perRemaining: per,
    weekAvg: days.fold<int>(0, (sum, day) => sum + day.kcal) / 7,
  );
}
