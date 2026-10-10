/// The Dart half of the cross-language meal-slot parity gate.
///
/// `diet_guard/tests/test_meal_schedule_vectors.py` asserts the *same*
/// expectations against the *same* `tests/fixtures/meal_schedule_vectors.json`.
/// Two independently written suites from the same prose is not a gate -- one
/// shared input with one shared expected result is: a device that derives a
/// slot its peer never offers has a checkpoint that can never be satisfied,
/// i.e. a permanent lock. Regenerate with
/// `scripts/build_meal_schedule_fixture.py`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:flutter_test/flutter_test.dart';

/// The repo root, found by walking up from wherever `flutter test` runs.
Directory get _repoRoot {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate app/ from ${Directory.current.path}');
    }
    dir = parent;
  }
  // `dir` is app/; the fixture is shared, so it lives at the repo root.
  return dir.parent;
}

File get _fixtureFile =>
    File('${_repoRoot.path}/tests/fixtures/meal_schedule_vectors.json');

MealSchedule _schedule(Object? row) {
  final values = (row! as List).cast<int>();
  return MealSchedule(
    firstMinute: values[0],
    lastMinute: values[1],
    count: values[2],
  );
}

DateTime _at(int minute) => DateTime(2026, 1, 1, minute ~/ 60, minute % 60);

List<int> _ints(Object? value) => (value! as List).cast<int>();

void main() {
  late Map<String, dynamic> vectors;

  setUpAll(() {
    vectors =
        jsonDecode(_fixtureFile.readAsStringSync()) as Map<String, dynamic>;
  });

  List<Map<String, dynamic>> rows(String key) =>
      (vectors[key] as List).cast<Map<String, dynamic>>();

  test('the shared fixture is present', () {
    expect(
      _fixtureFile.existsSync(),
      isTrue,
      reason: 'shared parity fixture missing at ${_fixtureFile.path}',
    );
  });

  test('schedules: normalised form, slots, cutoff and wire', () {
    expect(rows('schedules'), isNotEmpty);
    for (final row in rows('schedules')) {
      final schedule = _schedule(row['input']);
      final reason = '${row['input']}';
      expect(
        schedule.normalized(),
        _schedule(row['normalized']),
        reason: reason,
      );
      expect(schedule.slots(), _ints(row['slots']), reason: reason);
      expect(
        schedule.enforcementEndMinute,
        row['enforcement_end_minute'],
        reason: reason,
      );
      expect(scheduleToWire(schedule), row['wire'], reason: reason);
      expect(
        scheduleFromWire(row['wire']),
        schedule.normalized(),
        reason: reason,
      );
    }
  });

  test('time edges: every clock-reading function', () {
    expect(rows('time_edges'), isNotEmpty);
    for (final row in rows('time_edges')) {
      final schedule = _schedule(row['schedule']);
      final now = _at(row['minute'] as int);
      final reason = '${row['schedule']} @ ${row['minute']}';
      expect(
        withinEnforcementWindow(now, schedule),
        row['within_window'],
        reason: reason,
      );
      expect(
        elapsedSlots(now, schedule),
        _ints(row['elapsed']),
        reason: reason,
      );
      expect(currentSlot(now, schedule), row['current_slot'], reason: reason);
      expect(slotForLog(now, schedule), row['slot_for_log'], reason: reason);
    }
  });

  test('missing slots', () {
    for (final row in rows('missing')) {
      final actual = missingSlots(
        _at(row['minute'] as int),
        _ints(row['logged']).toSet(),
        _schedule(row['schedule']),
      );
      expect(actual, _ints(row['missing']), reason: '$row');
    }
  });

  test('nearest slot', () {
    for (final row in rows('nearest')) {
      final actual = nearestSlot(
        row['minute'] as int,
        _schedule(row['schedule']),
      );
      expect(actual, row['nearest'], reason: '$row');
    }
  });

  test('satisfied slots', () {
    for (final row in rows('satisfied')) {
      final actual = satisfiedSlots(
        _ints(row['entry_minutes']),
        _schedule(row['schedule']),
      ).toList()..sort();
      expect(actual, _ints(row['satisfied']), reason: '${row['name']}');
    }
  });

  test('labels', () {
    for (final row in rows('labels')) {
      expect(slotLabel(row['minute'] as int), row['label'], reason: '$row');
    }
  });

  test('schedule wire decode', () {
    for (final row in rows('schedule_wire_decode')) {
      final expected = row['schedule'] == null
          ? null
          : _schedule(row['schedule']);
      expect(scheduleFromWire(row['raw']), expected, reason: '$row');
    }
  });

  test('slot fields', () {
    for (final row in rows('slot_fields')) {
      final minute = row['minute'] as int;
      if (row['error'] == true) {
        expect(() => slotFields(minute), throwsArgumentError, reason: '$row');
      } else {
        expect(slotFields(minute), row['fields'], reason: '$row');
      }
    }
  });

  test('entry slot minute', () {
    for (final row in rows('entry_slot_minute')) {
      final entry = (row['entry'] as Map).cast<String, Object?>();
      expect(entrySlotMinute(entry), row['minute'], reason: '$row');
    }
  });
}
