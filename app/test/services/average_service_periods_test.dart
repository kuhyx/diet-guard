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

  group('weeklyAverage', () {
    test('the current week stops at yesterday', () {
      final log = logOf({
        '2026-01-05': 3000,
        '2026-01-06': 3000,
        '2026-01-07': 3000,
        '2026-01-08': 100,
      });
      final result = weeklyAverage(
        log,
        schedule: flat(2000),
        today: DateTime(2026, 1, 8),
      );
      expect(result.avgKcal, 3000);
      expect(result.end, '2026-01-07');
      expect(result.band, AverageBand.veryOver);
    });

    test('Monday has no complete days this week', () {
      final result = weeklyAverage(
        logOf({'2026-01-05': 3000}),
        schedule: flat(2000),
        today: DateTime(2026, 1, 5),
      );
      expect(result.elapsedDays, 0);
      expect(result.avgKcal, isNull);
    });

    test('the previous week is whole', () {
      final result = weeklyAverage(
        logOf({'2026-01-05': 2100, '2026-01-11': 2100}),
        schedule: flat(2000),
        weeksAgo: 1,
        today: DateTime(2026, 1, 14),
      );
      expect(result.start, '2026-01-05');
      expect(result.end, '2026-01-11');
      expect(result.elapsedDays, 7);
      expect(result.band, AverageBand.slightlyOver);
    });
  });
  group('monthlyAverage', () {
    test('the current month stops at yesterday', () {
      final log = logOf({
        '2026-03-01': 1000,
        '2026-03-02': 1000,
        '2026-03-04': 9000,
      });
      final result = monthlyAverage(
        log,
        schedule: flat(2000),
        today: DateTime(2026, 3, 4),
      );
      expect(result.avgKcal, 1000);
      expect(result.end, '2026-03-03');
      expect(result.band, AverageBand.under);
    });

    test('the first of the month has no complete days', () {
      final result = monthlyAverage(
        const {},
        schedule: flat(2000),
        today: DateTime(2026, 3),
      );
      expect(result.elapsedDays, 0);
    });

    test('the previous month is whole', () {
      final result = monthlyAverage(
        logOf({'2026-02-10': 2500}),
        schedule: flat(2000),
        monthsAgo: 1,
        today: DateTime(2026, 3, 10),
      );
      expect(result.start, '2026-02-01');
      expect(result.end, '2026-02-28');
      expect(result.elapsedDays, 28);
      expect(result.band, AverageBand.veryOver);
    });
  });
  group('date arithmetic across a DST boundary', () {
    test('lastCompleteDay is yesterday even across spring-forward', () {
      final result = lastCompleteDay(DateTime(2026, 3, 30));
      expect(
        (result.year, result.month, result.day),
        (2026, 3, 29),
        reason: 'Duration-based arithmetic returned 2026-03-28 23:00 here',
      );
    });

    test('a period spanning spring-forward keeps every day', () {
      final result = periodAverage(
        logOf({
          '2026-03-27': 2000,
          '2026-03-28': 2000,
          '2026-03-29': 2000,
          '2026-03-30': 2000,
          '2026-03-31': 2000,
        }),
        schedule: flat(2000),
        start: DateTime(2026, 3, 27),
        end: DateTime(2026, 3, 31),
      );
      expect(result.elapsedDays, 5);
      expect(
        result.loggedDays,
        5,
        reason: 'the day-stepping loop used to drop 2026-03-31',
      );
    });

    test('the weeksAgo anchor stays in the right ISO week', () {
      // 2026-04-01 is a Wednesday; one week back is the Mon 03-23..Sun 03-29
      // week, the one containing the clock change.
      final result = weeklyAverage(
        logOf({'2026-03-23': 2000, '2026-03-29': 2000}),
        schedule: flat(2000),
        weeksAgo: 1,
        today: DateTime(2026, 4),
      );
      expect(result.start, '2026-03-23');
      expect(result.end, '2026-03-29');
      expect(result.loggedDays, 2);
    });

    test('weekBounds spans Monday to Sunday across the change', () {
      final (monday, sunday) = weekBounds(DateTime(2026, 3, 29));
      expect((monday.year, monday.month, monday.day), (2026, 3, 23));
      expect((sunday.year, sunday.month, sunday.day), (2026, 3, 29));
    });

    test('monthBounds ends on the real last day of a DST month', () {
      final (first, last) = monthBounds(DateTime(2026, 3, 15));
      expect((first.year, first.month, first.day), (2026, 3, 1));
      expect((last.year, last.month, last.day), (2026, 3, 31));
    });
  });
}
