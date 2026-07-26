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

  group('loggingStreak', () {
    test('empty map is zero', () {
      expect(loggingStreak({}, today: DateTime(2026, 1, 5)), 0);
    });

    test('counts consecutive logged days including today', () {
      final sm = {
        '2026-01-03': DayStatus.green,
        '2026-01-04': DayStatus.red,
        '2026-01-05': DayStatus.yellow,
      };
      expect(loggingStreak(sm, today: DateTime(2026, 1, 5)), 3);
    });

    test('breaks on a gap', () {
      final sm = {
        '2026-01-01': DayStatus.green,
        '2026-01-03': DayStatus.green,
        '2026-01-04': DayStatus.green,
      };
      expect(loggingStreak(sm, today: DateTime(2026, 1, 4)), 2);
    });

    test('today not logged is not a break', () {
      final sm = {
        '2026-01-03': DayStatus.green,
        '2026-01-04': DayStatus.yellow,
      };
      expect(loggingStreak(sm, today: DateTime(2026, 1, 5)), 2);
    });

    test('yesterday not logged breaks streak even if today is', () {
      final sm = {
        '2026-01-03': DayStatus.green,
        '2026-01-05': DayStatus.green,
      };
      expect(loggingStreak(sm, today: DateTime(2026, 1, 5)), 1);
    });
  });

  group('adherenceStreak', () {
    test('counts consecutive green and yellow', () {
      final sm = {
        '2026-01-03': DayStatus.green,
        '2026-01-04': DayStatus.yellow,
        '2026-01-05': DayStatus.green,
      };
      expect(adherenceStreak(sm, today: DateTime(2026, 1, 5)), 3);
    });

    test('red today breaks the streak immediately', () {
      final sm = {
        '2026-01-04': DayStatus.green,
        '2026-01-05': DayStatus.red,
      };
      expect(adherenceStreak(sm, today: DateTime(2026, 1, 5)), 0);
    });

    test('not-logged today is not a break', () {
      final sm = {'2026-01-04': DayStatus.green};
      expect(adherenceStreak(sm, today: DateTime(2026, 1, 5)), 1);
    });

    test('red in history breaks the streak', () {
      final sm = {
        '2026-01-03': DayStatus.green,
        '2026-01-04': DayStatus.red,
        '2026-01-05': DayStatus.green,
      };
      expect(adherenceStreak(sm, today: DateTime(2026, 1, 5)), 1);
    });
  });

  group('yearToDateTally', () {
    test('counts logged and adherent days this year only', () {
      final sm = {
        '2026-01-01': DayStatus.green,
        '2026-01-02': DayStatus.red,
        '2026-01-03': DayStatus.notLogged,
        '2025-12-31': DayStatus.green,
      };
      final tally = yearToDateTally(sm, today: DateTime(2026, 1, 3));
      expect(tally.loggedDays, 2);
      expect(tally.elapsedDays, 3);
      expect(tally.adherentDays, 1);
    });

    test('future day in map is excluded', () {
      final sm = {
        '2026-01-01': DayStatus.green,
        '2026-06-01': DayStatus.green,
      };
      final tally = yearToDateTally(sm, today: DateTime(2026));
      expect(tally.loggedDays, 1);
      expect(tally.elapsedDays, 1);
      expect(tally.adherentDays, 1);
    });

    test('empty map', () {
      final tally = yearToDateTally({}, today: DateTime(2026, 3));
      expect(tally.loggedDays, 0);
      expect(tally.elapsedDays, 60);
      expect(tally.adherentDays, 0);
    });
  });
}
