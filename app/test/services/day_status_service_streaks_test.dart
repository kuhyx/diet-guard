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
