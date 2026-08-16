/// Tests for the pure meal-schedule derivation.
///
/// The vector table below is duplicated verbatim from
/// `diet_guard/tests/test_meal_schedule.py`. KEEP THE TWO IN SYNC: it is the
/// only thing that catches a Python/Dart divergence before it reaches a
/// device, and a divergence there means one device nags for a checkpoint the
/// other never offers -- a slot that can never be satisfied, i.e. a permanent
/// lock.
library;

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

/// (first, last, count, expected slots). Shared with the Python mirror.
const List<(int, int, int, List<int>)> scheduleVectors = [
  // The eating window the user described, at every supported meal count.
  (8, 20, 2, [8, 20]),
  (8, 20, 3, [8, 14, 20]),
  (8, 20, 4, [8, 12, 16, 20]), // today's hardcoded schedule
  (8, 20, 5, [8, 11, 14, 17, 20]), // the user's stated example
  (8, 20, 6, [8, 10, 13, 15, 18, 20]),
  // A window that does not divide evenly: 14 hours across 3 gaps.
  (7, 21, 4, [7, 12, 16, 21]),
  (7, 21, 5, [7, 11, 14, 18, 21]),
  (9, 19, 4, [9, 12, 16, 19]),
  // Narrow windows: count is capped at the number of whole hours available,
  // so the slots stay distinct instead of repeating an hour.
  (8, 12, 6, [8, 9, 10, 11, 12]),
  (8, 10, 5, [8, 9, 10]),
  (8, 9, 4, [8, 9]),
  // Whole-day extremes.
  (0, 23, 6, [0, 5, 9, 14, 18, 23]),
  (0, 1, 2, [0, 1]),
];

void main() {
  group('slots', () {
    for (final (first, last, count, expected) in scheduleVectors) {
      test('$first-$last x$count derives $expected', () {
        expect(
          MealSchedule(first: first, last: last, count: count).slots(),
          expected,
        );
      });
    }

    test('the default is the historical schedule', () {
      expect(kDefaultSchedule.slots(), [8, 12, 16, 20]);
    });

    test('endpoints stay exact when the spacing rounds', () {
      final slots = const MealSchedule(first: 8, last: 20, count: 6).slots();
      expect(slots.first, 8);
      expect(slots.last, 20);
    });
  });

  group('normalized', () {
    const cases = <(MealSchedule, MealSchedule)>[
      (
        MealSchedule(first: 8, last: 20, count: 99),
        MealSchedule(first: 8, last: 20, count: kMaxMealCount),
      ),
      (
        MealSchedule(first: 8, last: 20, count: 0),
        MealSchedule(first: 8, last: 20, count: kMinMealCount),
      ),
      (
        MealSchedule(first: -5, last: 20, count: 4),
        MealSchedule(first: 0, last: 20, count: 4),
      ),
      (
        MealSchedule(first: 8, last: 99, count: 4),
        MealSchedule(first: 8, last: 23, count: 4),
      ),
      // last <= first is pulled forward to leave a one-hour window.
      (
        MealSchedule(first: 12, last: 12, count: 4),
        MealSchedule(first: 12, last: 13, count: 2),
      ),
      (
        MealSchedule(first: 12, last: 3, count: 4),
        MealSchedule(first: 12, last: 13, count: 2),
      ),
      // first cannot occupy the final hour, or no window would remain.
      (
        MealSchedule(first: 23, last: 23, count: 2),
        MealSchedule(first: 22, last: 23, count: 2),
      ),
    ];

    for (final (input, expected) in cases) {
      test('$input clamps to $expected', () {
        expect(input.normalized(), expected);
      });
    }

    test('garbage still yields usable slots', () {
      expect(
        const MealSchedule(first: 99, last: -5, count: 999).slots(),
        [22, 23],
      );
    });
  });

  group('enforcementEndHour', () {
    test('the default keeps the historical 22:00 cutoff', () {
      expect(kDefaultSchedule.enforcementEndHour, 22);
    });

    test('the tail follows the last meal', () {
      expect(
        const MealSchedule(first: 8, last: 18, count: 4).enforcementEndHour,
        20,
      );
    });

    test('is clamped to the end of the day', () {
      // An unclamped 23 + 2 = 25 would make `hour < cutoff` vacuously true,
      // so the enforcement window would never close.
      expect(
        const MealSchedule(first: 8, last: 23, count: 4).enforcementEndHour,
        24,
      );
    });
  });

  test('every input yields ascending slots with exact endpoints', () {
    // The Dart half of the cross-language parity guarantee; the Python mirror
    // runs the identical sweep.
    for (var first = -2; first < 26; first++) {
      for (var last = -2; last < 26; last++) {
        for (var count = -2; count < 10; count++) {
          final schedule = MealSchedule(
            first: first,
            last: last,
            count: count,
          );
          final normalized = schedule.normalized();
          final slots = schedule.slots();

          expect(slots.first, normalized.first);
          expect(slots.last, normalized.last);
          expect(slots.length, normalized.count);
          expect(slots.toSet().length, slots.length);
          expect(slots, orderedEquals(List<int>.of(slots)..sort()));
          expect(slots.length, greaterThanOrEqualTo(kMinMealCount));
          expect(slots.length, lessThanOrEqualTo(kMaxMealCount));
        }
      }
    }
  });
}
