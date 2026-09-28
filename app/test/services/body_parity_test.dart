/// The Dart half of the cross-language Body parity gate.
///
/// `diet_guard/tests/test_body_parity.py` asserts the same expectations
/// against the same `tests/fixtures/body_calc.json` (built from the Python
/// reference by `scripts/build_body_fixture.py`), so the PC and the phone
/// print the same BMI, ideal weights, calorie table, exercise kcal and week
/// plan for the same person.
library;

import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/services/body_calc.dart';
import 'package:diet_guard_app/services/body_energy.dart';
import 'package:diet_guard_app/services/body_prefs.dart';
import 'package:diet_guard_app/services/body_steps.dart';
import 'package:diet_guard_app/services/week_plan.dart';
import 'package:flutter_test/flutter_test.dart';

Directory get _repoRoot {
  var dir = Directory.current;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate app/ from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.parent;
}

Map<String, dynamic> _loadFixture() =>
    jsonDecode(
          File(
            '${_repoRoot.path}/tests/fixtures/body_calc.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

void _close(Object? actual, Object? expected, String what) {
  if (expected == null) {
    expect(actual, isNull, reason: what);
    return;
  }
  expect(actual, isNotNull, reason: what);
  expect(
    actual! as num,
    closeTo((expected as num).toDouble(), 1e-9),
    reason: what,
  );
}

Biometrics _bio(Map<String, dynamic> raw) => Biometrics(
  weightKg: (raw['weight_kg'] as num).toDouble(),
  heightCm: (raw['height_cm'] as num).toDouble(),
  ageYears: (raw['age_years'] as num).toDouble(),
  isMale: raw['is_male'] as bool,
);

Session _session(Map<String, dynamic> raw) => Session(
  day: raw['day'] as String,
  kind: raw['kind'] as String,
  minutes: (raw['minutes'] as num).toDouble(),
  km: (raw['km'] as num?)?.toDouble(),
  label: raw['label'] as String,
  source: raw['source'] as String,
  start: raw['start'] as String?,
  end: raw['end'] as String?,
);

void main() {
  final fixture = _loadFixture();
  final today = DateTime.parse(fixture['today'] as String);
  final steps = (fixture['steps'] as Map<String, dynamic>).map(
    (day, n) => MapEntry(day, n as int),
  );
  final sessions = (fixture['sessions'] as List<dynamic>)
      .map((raw) => _session(raw as Map<String, dynamic>))
      .toList();

  group('people', () {
    final people = fixture['people'] as List<dynamic>;
    for (var index = 0; index < people.length; index++) {
      final person = people[index] as Map<String, dynamic>;
      final bio = _bio(person['bio'] as Map<String, dynamic>);
      test('person $index: BMI, ideal weight, BMR', () {
        final bmi = bmiReport(bio);
        final expected = person['bmi'] as Map<String, dynamic>;
        _close(bmi.bmi, expected['bmi'], 'bmi');
        _close(bmi.prime, expected['prime'], 'prime');
        _close(bmi.trefethen, expected['trefethen'], 'trefethen');
        expect(bmi.category, expected['category']);
        final fat = (person['body_fat_pct'] as num).toDouble();
        for (final (name, list) in [
          ('ideal', idealWeights(bio)),
          ('bmr', bmrFormulas(bio)),
          ('bmr_with_fat', bmrFormulas(bio, fat)),
        ]) {
          final rows = person[name] as List<dynamic>;
          expect(list, hasLength(rows.length));
          for (var i = 0; i < rows.length; i++) {
            final row = rows[i] as List<dynamic>;
            expect(list[i].name, row[0]);
            _close(list[i].value, row[1], '$name ${row[0]}');
          }
        }
      });
      test('person $index: healthy range and ideal summary', () {
        final (low, high) = healthyRange(bio);
        final range = person['healthy_range'] as List<dynamic>;
        _close(low, range[0], 'healthy low');
        _close(high, range[1], 'healthy high');
        final summary = idealSummary(idealWeights(bio))!;
        final expected = person['ideal_summary'] as List<dynamic>;
        _close(summary.$1, expected[0], 'ideal avg');
        _close(summary.$2, expected[1], 'ideal min');
        _close(summary.$3, expected[2], 'ideal max');
      });
      test('person $index: steps, exercise and goal targets', () {
        _close(strideM(bio), person['stride_m'], 'stride');
        final stepKcals = (person['step_kcal'] as Map<String, dynamic>);
        final byDay = <String, double>{};
        for (final entry in steps.entries) {
          byDay[entry.key] = stepKcal(entry.value, bio);
          _close(byDay[entry.key], stepKcals[entry.key], 'steps ${entry.key}');
        }
        final exercise = dailyExercise(sessions, bio.weightKg, today, byDay);
        for (final (key, actual) in [
          ('exercise', exercise),
          ('exercise_no_steps', dailyExercise(sessions, bio.weightKg, today)),
          // History younger than 14 days: averaged from its first day.
          (
            'exercise_short',
            dailyExercise(
              [
                for (final x in sessions)
                  if (x.day.compareTo('2026-09-24') >= 0) x,
              ],
              bio.weightKg,
              today,
            ),
          ),
          // Only today's in-progress session: no past data, all zero.
          (
            'exercise_today_only',
            dailyExercise(
              [
                for (final x in sessions)
                  if (x.day == '2026-09-28') x,
              ],
              bio.weightKg,
              today,
            ),
          ),
        ]) {
          final expected = person[key] as Map<String, dynamic>;
          expect(actual.keys.toList(), expected.keys.toList());
          for (final name in expected.keys) {
            _close(actual[name], expected[name], '$key $name');
          }
        }
        for (final raw in person['targets'] as List<dynamic>) {
          final row = raw as Map<String, dynamic>;
          final fat = (row['body_fat_pct'] as num?)?.toDouble();
          final goal = goalFromJson(row['goal']);
          expect(goalToJson(goal), row['goal']);
          final bmr = tableBmr(bio, fat);
          final target = goalTarget(goal, bmr.value!, bmr.name, exercise);
          final what = '${row['goal']} fat=$fat';
          expect(target.kcal, row['kcal'], reason: what);
          _close(target.tdee, row['tdee'], what);
          expect(target.bmrName, row['bmr_name'], reason: what);
        }
      });
    }
  });

  test('session kcal at 80 kg', () {
    final expected = fixture['session_kcal_80kg'] as List<dynamic>;
    for (var i = 0; i < sessions.length; i++) {
      final result = sessionKcal(sessions[i], 80);
      final row = expected[i] as Map<String, dynamic>;
      final kcal = row['kcal'] as Map<String, dynamic>;
      expect(result.kcal.keys.toList(), kcal.keys.toList());
      for (final name in kcal.keys) {
        _close(result.kcal[name], kcal[name], 'session $i $name');
      }
      expect(result.fallback.toList()..sort(), row['fallback']);
    }
  });

  test('week plans', () {
    for (final raw in fixture['plans'] as List<dynamic>) {
      final plan = raw as Map<String, dynamic>;
      final result = planWeek(
        DateTime.parse(plan['today'] as String),
        plan['target'] as int,
        (plan['logged'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, (v as num).toDouble()),
        ),
        (plan['typed'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(int.parse(k), v as int),
        ),
      );
      final expected = plan['expected'] as Map<String, dynamic>;
      expect(result.targetAvg, expected['target_avg']);
      expect(result.perRemaining, expected['per_remaining']);
      _close(result.weekAvg, expected['week_avg'], 'week_avg');
      final days = expected['days'] as List<dynamic>;
      for (var i = 0; i < 7; i++) {
        final day = days[i] as Map<String, dynamic>;
        expect(result.days[i].day, day['day']);
        expect(result.days[i].weekday, day['weekday']);
        expect(result.days[i].kcal, day['kcal']);
        expect(result.days[i].source, day['source']);
      }
    }
  });
}
