// Mirror of `diet_guard/tests/test_budget_history.py`'s pure half. Keep the
// two in lockstep: a divergence means the PC and the phone resolve the same
// day to different budgets.

import 'dart:convert';

import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

BudgetEntry _entry(
  String day,
  int kcal, [
  String t = '2026-01-01T00:00:00.000Z',
]) => BudgetEntry(effectiveFrom: day, kcal: kcal, editedAt: t);

void main() {
  group('forDay', () {
    test('empty history falls back to the default', () {
      expect(BudgetSchedule.empty.forDay('2026-06-01'), kDefaultDailyKcalGoal);
    });

    test('day before every entry falls back to the fallback', () {
      final schedule = BudgetSchedule([
        _entry('2026-07-26', 2000),
      ], fallback: 2200);
      expect(schedule.forDay('2026-06-01'), 2200);
    });

    test('exact effective-from day uses the new value', () {
      final schedule = BudgetSchedule([
        _entry('2026-07-26', 2000),
      ], fallback: 2200);
      expect(schedule.forDay('2026-07-26'), 2000);
    });

    test('day after uses the new value', () {
      final schedule = BudgetSchedule([
        _entry('2026-07-26', 2000),
      ], fallback: 2200);
      expect(schedule.forDay('2026-07-27'), 2000);
    });

    test('between entries uses the earlier one', () {
      final schedule = BudgetSchedule([
        _entry(kEpochDay, 2200),
        _entry('2026-07-26', 2000),
      ], fallback: 1);
      expect(schedule.forDay('2026-07-25'), 2200);
      expect(schedule.forDay('2026-07-26'), 2000);
    });

    test('picks the latest of several changes', () {
      final schedule = BudgetSchedule([
        _entry(kEpochDay, 2400),
        _entry('2026-03-01', 2200),
        _entry('2026-07-26', 2000),
      ], fallback: 1);
      expect(schedule.forDay('2026-02-28'), 2400);
      expect(schedule.forDay('2026-05-05'), 2200);
      expect(schedule.forDay('2026-12-31'), 2000);
    });

    test('current resolves today', () {
      final schedule = BudgetSchedule([_entry(kEpochDay, 1900)], fallback: 1);
      expect(schedule.current, 1900);
    });
  });

  group('parse', () {
    test('round trips entries', () {
      final entries = [_entry(kEpochDay, 2200), _entry('2026-07-26', 2000)];
      final raw = jsonDecode(jsonEncode(BudgetSchedule.encode(entries)));
      expect(BudgetSchedule.parse(raw), entries);
    });

    test('sorts ascending regardless of stored order', () {
      final raw = {
        'v': 1,
        'e': {
          '2026-07-26': {'b': 2000, 't': 'x'},
          '1970-01-01': {'b': 2200, 't': 'y'},
        },
      };
      expect(BudgetSchedule.parse(raw).map((e) => e.effectiveFrom).toList(), [
        '1970-01-01',
        '2026-07-26',
      ]);
    });

    test('non-map is empty', () {
      expect(BudgetSchedule.parse([1, 2, 3]), isEmpty);
    });

    test('wrong version is empty', () {
      expect(
        BudgetSchedule.parse({'v': 99, 'e': <String, dynamic>{}}),
        isEmpty,
      );
    });

    test('non-map entries container is empty', () {
      expect(BudgetSchedule.parse({'v': 1, 'e': 'nope'}), isEmpty);
    });

    test('malformed entries are skipped', () {
      final raw = {
        'v': 1,
        'e': {
          '2026-07-26': 'not a record',
          '2026-07-27': {'b': 'not an int'},
          '2026-07-29': {'b': 2000, 't': '2026-07-29T00:00:00.000Z'},
        },
      };
      expect(BudgetSchedule.parse(raw).map((e) => e.effectiveFrom).toList(), [
        '2026-07-29',
      ]);
    });

    test('missing edit time falls back to the epoch', () {
      final entries = BudgetSchedule.parse({
        'v': 1,
        'e': {
          '2026-07-26': {'b': 2000},
        },
      });
      expect(entries.single.editedAt, startsWith('1970-01-01'));
    });
  });

  group('upsert', () {
    test('appends a new day', () {
      final schedule = BudgetSchedule([
        _entry(kEpochDay, 2200),
      ]).upsert(2000, when: DateTime(2026, 7, 26, 10));
      expect(schedule.entries.map((e) => e.effectiveFrom).toList(), [
        kEpochDay,
        '2026-07-26',
      ]);
      expect(schedule.entries.last.kcal, 2000);
    });

    test('a second edit the same day replaces rather than appends', () {
      var schedule = BudgetSchedule.empty.upsert(
        2000,
        when: DateTime(2026, 7, 26, 10),
      );
      schedule = schedule.upsert(1900, when: DateTime(2026, 7, 26, 18, 30));
      expect(schedule.entries, hasLength(1));
      expect(schedule.entries.single.kcal, 1900);
    });
  });

  group('seed', () {
    test('grandfathers the value to the epoch day', () {
      final seeded = BudgetSchedule.seed(2200, DateTime.utc(2026, 7, 13, 19));
      expect(seeded.single.effectiveFrom, kEpochDay);
      expect(seeded.single.kcal, 2200);
      expect(seeded.single.editedAt, startsWith('2026-07-13'));
    });

    test('a null edit time falls back to the epoch', () {
      expect(
        BudgetSchedule.seed(2200, null).single.editedAt,
        startsWith('1970'),
      );
    });
  });
}
