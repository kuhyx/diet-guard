import 'package:diet_guard_app/models/day_status.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/day_status_service.dart';
import 'package:flutter_test/flutter_test.dart';

FoodEntry buildEntry({required double kcal, bool deleted = false}) => FoodEntry(
  time: '2026-01-01T12:00:00',
  desc: 'test',
  grams: 100,
  kcal: kcal,
  proteinG: 0,
  carbsG: 0,
  fatG: 0,
  source: 'manual',
  deleted: deleted,
);

FoodEntry buildMacroEntry({
  required double proteinG,
  required double carbsG,
  required double fatG,
}) => FoodEntry(
  time: '2026-01-01T12:00:00',
  desc: 'test',
  grams: 100,
  kcal: 0,
  proteinG: proteinG,
  carbsG: carbsG,
  fatG: fatG,
  source: 'manual',
);

/// A schedule where one budget has applied since the beginning of time.
BudgetSchedule flat(int budget) => BudgetSchedule(
  [const BudgetEntry(effectiveFrom: kEpochDay, kcal: 0, editedAt: '')]
      .map(
        (_) => BudgetEntry(
          effectiveFrom: kEpochDay,
          kcal: budget,
          editedAt: '1970-01-01T00:00:00.000Z',
        ),
      )
      .toList(),
  fallback: budget,
);

void main() {
  group('dayTotalKcal', () {
    test('sums entries for the day', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 100), buildEntry(kcal: 50)],
      };
      expect(dayTotalKcal(log, '2026-01-01'), 150);
    });

    test('missing day is zero', () {
      expect(dayTotalKcal(<String, List<FoodEntry>>{}, '2026-01-01'), 0);
    });

    test('excludes tombstoned entries', () {
      final log = {
        '2026-01-01': [
          buildEntry(kcal: 100),
          buildEntry(kcal: 50, deleted: true),
        ],
      };
      expect(dayTotalKcal(log, '2026-01-01'), 100);
    });
  });
  group('sumMacros', () {
    test('sums protein, carbs and fat across entries', () {
      final totals = sumMacros([
        buildMacroEntry(proteinG: 10, carbsG: 20, fatG: 5),
        buildMacroEntry(proteinG: 5, carbsG: 30, fatG: 2.5),
      ]);
      expect(totals.proteinG, 15);
      expect(totals.carbsG, 50);
      expect(totals.fatG, 7.5);
    });

    test('is all zeroes for no entries', () {
      final totals = sumMacros(const []);
      expect(totals.proteinG, 0);
      expect(totals.carbsG, 0);
      expect(totals.fatG, 0);
    });
  });
  group('dayStatus', () {
    test('missing day is notLogged', () {
      final log = <String, List<FoodEntry>>{};
      expect(dayStatus(log, '2026-01-01', 2000), DayStatus.notLogged);
    });

    test('a day with only tombstoned entries is notLogged, not green', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 100, deleted: true)],
      };
      expect(dayStatus(log, '2026-01-01', 2000), DayStatus.notLogged);
    });

    test('exactly at budget is green', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 2000)],
      };
      expect(dayStatus(log, '2026-01-01', 2000), DayStatus.green);
    });

    test('under budget is green', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 1000)],
      };
      expect(dayStatus(log, '2026-01-01', 2000), DayStatus.green);
    });

    test('just over budget is yellow', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 2001)],
      };
      expect(dayStatus(log, '2026-01-01', 2000), DayStatus.yellow);
    });

    test('exactly at yellow ceiling is yellow', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 2400)],
      };
      expect(dayStatus(log, '2026-01-01', 2000), DayStatus.yellow);
    });

    test('just over yellow ceiling is red', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 2400.01)],
      };
      expect(dayStatus(log, '2026-01-01', 2000), DayStatus.red);
    });

    test('way over budget is red', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 5000)],
      };
      expect(dayStatus(log, '2026-01-01', 2000), DayStatus.red);
    });
  });
  group('statusMap', () {
    test('maps every present day', () {
      final log = {
        '2026-01-01': [buildEntry(kcal: 1000)],
        '2026-01-02': [buildEntry(kcal: 5000)],
      };
      expect(statusMap(log, schedule: flat(2000)), {
        '2026-01-01': DayStatus.green,
        '2026-01-02': DayStatus.red,
      });
    });

    test('empty log is empty map', () {
      final log = <String, List<FoodEntry>>{};
      expect(statusMap(log, schedule: flat(2000)), <String, DayStatus>{});
    });
  });
}
