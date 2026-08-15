import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/period_average.dart';
import 'package:diet_guard_app/services/average_service.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
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

BudgetSchedule flat(int budget) => BudgetSchedule(
  [BudgetEntry(effectiveFrom: kEpochDay, kcal: budget, editedAt: '')],
  fallback: budget,
);

DayLog logOf(Map<String, double> kcalByDay) => {
  for (final e in kcalByDay.entries) e.key: [buildEntry(kcal: e.value)],
};

void main() {

  // Every other fixture in this file sits in a DST-free span, so none of them
  // can see the bug these cover: stepping a local DateTime by
  // Duration(days: 1) moves 23 or 25 hours across a DST boundary and lands on
  // the wrong wall-clock day.  Under TZ=Europe/Warsaw (spring-forward
  // 2026-03-29) that made the phone and the PC report different averages for
  // the same log.  Assertions are on the calendar day, never on the DateTime,
  // so they mean the same thing whatever zone the runner is in.

  group('bandFor', () {
    test('exactly at budget is under', () {
      expect(bandFor(2000, 2000), AverageBand.under);
    });
    test('one over is slightly over', () {
      expect(bandFor(2001, 2000), AverageBand.slightlyOver);
    });
    test('exactly at the 120% ceiling is slightly over', () {
      expect(bandFor(2400, 2000), AverageBand.slightlyOver);
    });
    test('just past the ceiling is very over', () {
      expect(bandFor(2400.01, 2000), AverageBand.veryOver);
    });
  });
  group('bandLabel', () {
    test('mirrors the Python labels exactly', () {
      expect(bandLabel(null), 'no data');
      expect(bandLabel(AverageBand.under), 'under');
      expect(bandLabel(AverageBand.slightlyOver), 'slightly over');
      expect(bandLabel(AverageBand.veryOver), 'very over');
    });
  });
  group('bounds', () {
    test('week starts on Monday', () {
      // 2026-01-07 is a Wednesday.
      final (start, end) = weekBounds(DateTime(2026, 1, 7));
      expect(start, DateTime(2026, 1, 5));
      expect(end, DateTime(2026, 1, 11));
    });
    test('a Sunday looks back to its own Monday', () {
      final (start, _) = weekBounds(DateTime(2026, 1, 11));
      expect(start, DateTime(2026, 1, 5));
    });
    test('month bounds cover a short February', () {
      final (start, end) = monthBounds(DateTime(2026, 2, 14));
      expect(start, DateTime(2026, 2));
      expect(end, DateTime(2026, 2, 28));
    });
    test('month bounds cover a leap February', () {
      final (_, end) = monthBounds(DateTime(2024, 2, 14));
      expect(end, DateTime(2024, 2, 29));
    });
    test('lastCompleteDay is yesterday', () {
      expect(lastCompleteDay(DateTime(2026, 3)), DateTime(2026, 2, 28));
    });
    test('shiftMonths wraps the year', () {
      expect(shiftMonths(DateTime(2026, 1, 20), 1), DateTime(2025, 12));
    });
  });
  group('periodAverage', () {
    test('averages over logged days only, not elapsed days', () {
      final log = logOf({
        '2026-01-05': 2000,
        '2026-01-06': 3000,
        '2026-01-09': 4000,
      });
      final result = periodAverage(
        log,
        schedule: flat(2500),
        start: DateTime(2026, 1, 5),
        end: DateTime(2026, 1, 9),
      );
      expect(result.avgKcal, 3000);
      expect(result.loggedDays, 3);
      expect(result.elapsedDays, 5);
    });

    test('tombstoned entries do not make a day count as logged', () {
      final log = <String, List<FoodEntry>>{
        '2026-01-05': [buildEntry(kcal: 9000, deleted: true)],
      };
      final result = periodAverage(
        log,
        schedule: flat(2000),
        start: DateTime(2026, 1, 5),
        end: DateTime(2026, 1, 5),
      );
      expect(result.loggedDays, 0);
      expect(result.avgKcal, isNull);
    });

    test('an empty period has a null average, not zero', () {
      final result = periodAverage(
        const {},
        schedule: flat(2000),
        start: DateTime(2026, 1, 5),
        end: DateTime(2026, 1, 11),
      );
      expect(result.avgKcal, isNull);
      expect(result.band, isNull);
      expect(result.elapsedDays, 7);
    });

    test('end before start is zero elapsed, not negative', () {
      final result = periodAverage(
        const {},
        schedule: flat(2000),
        start: DateTime(2026, 1, 5),
        end: DateTime(2026, 1, 4),
      );
      expect(result.elapsedDays, 0);
    });

    test('the budget is averaged per logged day, not taken from today', () {
      final schedule = BudgetSchedule([
        BudgetEntry(effectiveFrom: kEpochDay, kcal: 1000, editedAt: ''),
        BudgetEntry(effectiveFrom: '2026-01-06', kcal: 3000, editedAt: ''),
      ], fallback: 1000);
      final log = logOf({'2026-01-05': 2000, '2026-01-06': 2000});
      final result = periodAverage(
        log,
        schedule: schedule,
        start: DateTime(2026, 1, 5),
        end: DateTime(2026, 1, 6),
      );
      expect(result.avgBudget, 2000);
      expect(result.band, AverageBand.under);
    });
  });
}
