/// Exercise energy per workout, by every formula the workout data supports.
///
/// Port of `diet_guard/_activity_kcal.py`, gated by the shared
/// `tests/fixtures/body_calc.json`. Every formula returns **net** kcal --
/// energy above resting -- because the measured TDEE adds exercise on top of
/// `BMR x 1.2`, which already pays for the resting hour.
///
/// * **MET** (Compendium 2011): `(MET - 1) x kg x hours`, speed-interpolated
///   for runs and walks; lifting is code 02052 (resistance training) = 5.0.
/// * **ACSM** level-ground equations: net VO2 = 0.2 v (run) / 0.1 v (walk),
///   v in m/min; kcal = VO2 x kg x min x 5 / 1000.
/// * **Per-km**: 0.9 (run) / 0.5 (walk) kcal/kg/km net.
///
/// ACSM and per-km need a distance, so every other session falls back to
/// its MET figure (listed in [SessionKcal.fallback]).
library;

import 'package:diet_guard_app/models/workout_session.dart';

export 'package:diet_guard_app/models/workout_session.dart';

/// Formula names, in display order.
const List<String> activityFormulas = ['MET', 'ACSM', 'Per-km'];

/// The methods explained, shown under the Activity card.
const String methodsNote =
    'MET = standard activity values x your weight x time. '
    'ACSM = American College of Sports Medicine running/walking equation '
    'from your speed. Per-km = ~0.9 kcal per kg per km running, ~0.5 '
    'walking. All are energy above resting.';

/// Measured activity averages at most the last two full weeks.
const int maxWindowDays = 14;

const List<(double, double)> _runMetByKmh = [
  (6.4, 6),
  (8, 8.3),
  (8.4, 9),
  (9.7, 9.8),
  (10.8, 10.5),
  (11.3, 11),
  (12.1, 11.5),
  (12.9, 11.8),
  (13.8, 12.3),
  (14.5, 12.8),
  (16.1, 14.5),
  (17.7, 16),
  (19.3, 19),
  (20.9, 19.8),
  (22.5, 23),
];
const List<(double, double)> _walkMetByKmh = [
  (3.2, 2.8),
  (4, 3),
  (4.8, 3.5),
  (5.6, 4.3),
  (6.4, 5),
  (7.2, 7),
  (8, 8.3),
];
const Map<String, double> _fixedMet = {
  'strength': 5,
  'run': 8,
  'walk': 3.5,
  'cycle': 7.5,
  'other': 4,
};
const Map<String, double> _acsmSlope = {'run': 0.2, 'walk': 0.1};
const Map<String, double> _netKcalPerKgKm = {'run': 0.9, 'walk': 0.5};
const double _kcalPerLitreO2 = 5;

/// Net kcal of one session per formula; [fallback] names MET stand-ins.
class SessionKcal {
  /// Creates a result.
  const SessionKcal(this.session, this.kcal, this.fallback);

  /// The session measured.
  final Session session;

  /// Formula name -> net kcal.
  final Map<String, double> kcal;

  /// Formulas that could not apply and reuse the MET figure.
  final Set<String> fallback;
}

double _interpolate(List<(double, double)> table, double kmh) {
  if (kmh <= table.first.$1) return table.first.$2;
  for (var i = 0; i + 1 < table.length; i++) {
    final (x0, y0) = table[i];
    final (x1, y1) = table[i + 1];
    if (kmh <= x1) return y0 + (y1 - y0) * (kmh - x0) / (x1 - x0);
  }
  return table.last.$2;
}

double? _speedKmh(Session session) {
  final km = session.km;
  if (km == null || km <= 0 || session.minutes <= 0) return null;
  return km / (session.minutes / 60.0);
}

/// The MET value for [session]: speed-based when possible, else fixed.
double metFor(Session session) {
  final kmh = _speedKmh(session);
  if (kmh != null && session.kind == 'run') {
    return _interpolate(_runMetByKmh, kmh);
  }
  if (kmh != null && session.kind == 'walk') {
    return _interpolate(_walkMetByKmh, kmh);
  }
  return _fixedMet[session.kind] ?? _fixedMet['other']!;
}

/// Net kcal of [session] for a [weightKg] person, by every formula.
SessionKcal sessionKcal(Session session, double weightKg) {
  final hours = session.minutes / 60.0;
  final met = (metFor(session) - 1.0) * weightKg * hours;
  final kcal = {'MET': met, 'ACSM': met, 'Per-km': met};
  final fallback = {'ACSM', 'Per-km'};
  final kmh = _speedKmh(session);
  final km = session.km;
  final slope = _acsmSlope[session.kind];
  if (kmh != null && km != null && slope != null) {
    final metresPerMin = kmh * 1000.0 / 60.0;
    final netVo2 = slope * metresPerMin;
    kcal['ACSM'] = netVo2 * weightKg * session.minutes * _kcalPerLitreO2 / 1000;
    kcal['Per-km'] = _netKcalPerKgKm[session.kind]! * weightKg * km;
    fallback.clear();
  }
  return SessionKcal(session, kcal, fallback);
}

String _dateKey(DateTime day) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-${two(day.month)}'
      '-${two(day.day)}';
}

DateTime _utcDay(DateTime day) => DateTime.utc(day.year, day.month, day.day);

/// How many full past days [dailyExercise] averages over.
///
/// [maxWindowDays], or fewer while the earliest past data (a session or an
/// [extraByDay] key before [today]) is younger than that; 0 when there is no
/// past data at all.
int windowDays(
  List<Session> sessions,
  DateTime today, [
  Map<String, double>? extraByDay,
]) {
  final last = _dateKey(today);
  final days = [
    for (final session in sessions)
      if (session.day.compareTo(last) < 0) session.day,
    for (final day in (extraByDay ?? const <String, double>{}).keys)
      if (day.compareTo(last) < 0) day,
  ];
  if (days.isEmpty) return 0;
  final earliest = days.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
  // Whole UTC days, so a DST change cannot shave an hour off the count.
  final span = _utcDay(
    today,
  ).difference(DateTime.parse('${earliest}T00:00:00Z')).inDays;
  return span < maxWindowDays ? span : maxWindowDays;
}

/// Mean net exercise kcal per day over the full past days before [today].
///
/// The window ends yesterday (today is still in progress) and starts
/// [maxWindowDays] back -- or, while the data is younger than that, on the
/// first day that has any, so a week of history is averaged over that week
/// rather than diluted over 14 days ([windowDays]). The denominator is
/// calendar days within that span: a rest day burns no exercise kcal. With
/// no past data at all, every formula reads 0.
///
/// [extraByDay] (day -> net kcal, e.g. steps outside workouts) is added to
/// every formula alike: it is not a workout any formula could measure.
Map<String, double> dailyExercise(
  List<Session> sessions,
  double weightKg,
  DateTime today, [
  Map<String, double>? extraByDay,
]) {
  final totals = {for (final name in activityFormulas) name: 0.0};
  final span = windowDays(sessions, today, extraByDay);
  if (span == 0) return totals;
  // Calendar arithmetic via the constructor, not Duration: subtracting N x
  // 24 h across a DST change lands on 23:00 of the wrong day.
  final first = _dateKey(DateTime(today.year, today.month, today.day - span));
  final last = _dateKey(today);
  bool inWindow(String day) =>
      day.compareTo(first) >= 0 && day.compareTo(last) < 0;
  for (final session in sessions) {
    if (!inWindow(session.day)) continue;
    sessionKcal(session, weightKg).kcal.forEach((name, value) {
      totals[name] = totals[name]! + value;
    });
  }
  extraByDay?.forEach((day, kcal) {
    if (!inWindow(day)) return;
    for (final name in activityFormulas) {
      totals[name] = totals[name]! + kcal;
    }
  });
  return totals.map((name, total) => MapEntry(name, total / span));
}

/// The part of every [dailyExercise] mean that [extraByDay] contributes,
/// over the very same window -- so a "steps add N kcal/day (included above)"
/// line always adds up to the total it claims to be part of. Mirrors the
/// steps share computed in `diet_guard/_body_view.py`.
double extraShare(
  List<Session> sessions,
  DateTime today,
  Map<String, double> extraByDay,
) {
  final span = windowDays(sessions, today, extraByDay);
  if (span == 0) return 0;
  final first = _dateKey(DateTime(today.year, today.month, today.day - span));
  final last = _dateKey(today);
  var sum = 0.0;
  extraByDay.forEach((day, kcal) {
    if (day.compareTo(first) >= 0 && day.compareTo(last) < 0) sum += kcal;
  });
  return sum / span;
}
