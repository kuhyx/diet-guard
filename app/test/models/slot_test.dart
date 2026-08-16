import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('daySlots', () {
    test('returns the four fixed hourly slots', () {
      expect(daySlots(kDefaultSchedule), [8, 12, 16, 20]);
    });
  });

  group('withinEnforcementWindow', () {
    test('false before the day start hour', () {
      expect(
        withinEnforcementWindow(DateTime(2026, 6, 22, 7, 59), kDefaultSchedule),
        isFalse,
      );
    });

    test('true at the day start hour', () {
      expect(
        withinEnforcementWindow(DateTime(2026, 6, 22, 8, 0), kDefaultSchedule),
        isTrue,
      );
    });

    test('true just before the eating end hour', () {
      expect(
        withinEnforcementWindow(
          DateTime(2026, 6, 22, 21, 59),
          kDefaultSchedule,
        ),
        isTrue,
      );
    });

    test('false at the eating end hour (exclusive)', () {
      expect(
        withinEnforcementWindow(DateTime(2026, 6, 22, 22, 0), kDefaultSchedule),
        isFalse,
      );
    });
  });

  group('elapsedSlots', () {
    test('empty outside the enforcement window', () {
      expect(
        elapsedSlots(DateTime(2026, 6, 22, 23, 0), kDefaultSchedule),
        isEmpty,
      );
    });

    test('only the 8 slot right at day start', () {
      expect(elapsedSlots(DateTime(2026, 6, 22, 8, 0), kDefaultSchedule), [8]);
    });

    test('8 and 12 mid-afternoon before 16', () {
      expect(elapsedSlots(DateTime(2026, 6, 22, 15, 59), kDefaultSchedule), [
        8,
        12,
      ]);
    });

    test('all four slots once 20:00 has passed', () {
      expect(elapsedSlots(DateTime(2026, 6, 22, 21, 0), kDefaultSchedule), [
        8,
        12,
        16,
        20,
      ]);
    });
  });

  group('missingSlots', () {
    test('excludes already-logged elapsed slots', () {
      expect(
        missingSlots(DateTime(2026, 6, 22, 17, 0), {8}, kDefaultSchedule),
        [12, 16],
      );
    });

    test('empty once every elapsed slot is logged', () {
      expect(
        missingSlots(DateTime(2026, 6, 22, 17, 0), {
          8,
          12,
          16,
        }, kDefaultSchedule),
        isEmpty,
      );
    });
  });

  group('currentSlot', () {
    test('null outside the enforcement window', () {
      expect(
        currentSlot(DateTime(2026, 6, 22, 6, 0), kDefaultSchedule),
        isNull,
      );
    });

    test('returns the most recently elapsed slot', () {
      expect(currentSlot(DateTime(2026, 6, 22, 17, 41), kDefaultSchedule), 16);
    });

    test('returns 8 right at day start', () {
      expect(currentSlot(DateTime(2026, 6, 22, 8, 0), kDefaultSchedule), 8);
    });
  });

  group('slotForLog', () {
    // Keep in lockstep with `diet_guard/tests/test_slots.py`'s
    // TestSlotForLog: a divergence means the PC and the phone disagree about
    // which checkpoint a meal satisfied.
    DateTime at(int hour) => DateTime(2026, 6, 22, hour, 0);

    test('clamps to the first slot before the window opens', () {
      expect(slotForLog(at(7), kDefaultSchedule), 8);
    });

    test('clamps to the first slot in the small hours', () {
      expect(slotForLog(at(0), kDefaultSchedule), 8);
    });

    test('is unchanged exactly at the first slot', () {
      expect(slotForLog(at(8), kDefaultSchedule), 8);
    });

    test('matches currentSlot inside the window', () {
      expect(
        slotForLog(at(13), kDefaultSchedule),
        currentSlot(at(13), kDefaultSchedule),
      );
      expect(slotForLog(at(13), kDefaultSchedule), 12);
    });

    test('is unchanged at the last in-window hour', () {
      expect(slotForLog(at(21), kDefaultSchedule), 20);
    });

    test('clamps to the last slot once the window closes', () {
      expect(slotForLog(at(22), kDefaultSchedule), 20);
    });

    test('clamps to the last slot late in the evening', () {
      expect(slotForLog(at(23), kDefaultSchedule), 20);
    });

    test('never returns a slot outside the schedule', () {
      for (var hour = 0; hour < 24; hour++) {
        expect(
          daySlots(kDefaultSchedule),
          contains(slotForLog(at(hour), kDefaultSchedule)),
        );
      }
    });

    test('clamps the same way across configured schedules', () {
      // Sweeps every hour against several windows. `test_slots.py` runs the
      // identical sweep: the two must agree on every cell, because a device
      // that attributes a meal to a different slot than its peer leaves the
      // other device's checkpoint permanently unsatisfied.
      const schedules = [
        kDefaultSchedule,
        MealSchedule(first: 8, last: 20, count: 5),
        MealSchedule(first: 6, last: 22, count: 6),
        MealSchedule(first: 0, last: 23, count: 2),
        MealSchedule(first: 10, last: 14, count: 3),
      ];
      for (final schedule in schedules) {
        final slots = daySlots(schedule);
        for (var hour = 0; hour < 24; hour++) {
          final attributed = slotForLog(at(hour), schedule);
          expect(slots, contains(attributed));
          if (hour < slots.first) {
            expect(attributed, slots.first);
          } else if (hour >= schedule.enforcementEndHour) {
            expect(attributed, slots.last);
          } else {
            // Inside the window: the most recent slot that has opened.
            expect(attributed, slots.where((s) => s <= hour).last);
          }
        }
      }
    });
  });

  group('configured schedules', () {
    test('five meals shifts the checkpoints', () {
      const schedule = MealSchedule(first: 8, last: 20, count: 5);
      expect(daySlots(schedule), [8, 11, 14, 17, 20]);
      expect(elapsedSlots(DateTime(2026, 6, 22, 14), schedule), [8, 11, 14]);
      expect(
        missingSlots(DateTime(2026, 6, 22, 14), {8, 11}, schedule),
        [14],
      );
    });

    test('enforcement follows the last meal', () {
      const schedule = MealSchedule(first: 8, last: 18, count: 3);
      expect(
        withinEnforcementWindow(DateTime(2026, 6, 22, 19), schedule),
        isTrue,
      );
      expect(
        withinEnforcementWindow(DateTime(2026, 6, 22, 20), schedule),
        isFalse,
      );
      expect(elapsedSlots(DateTime(2026, 6, 22, 20), schedule), isEmpty);
    });

    test('midnight is a real slot, not a falsy absence', () {
      const schedule = MealSchedule(first: 0, last: 12, count: 3);
      expect(daySlots(schedule), [0, 6, 12]);
      expect(currentSlot(DateTime(2026, 6, 22), schedule), 0);
      expect(slotForLog(DateTime(2026, 6, 22), schedule), 0);
    });
  });

  group('slotLabel', () {
    test('pads single-digit hours', () {
      expect(slotLabel(8), '08:00');
    });

    test('formats double-digit hours', () {
      expect(slotLabel(20), '20:00');
    });
  });
}
