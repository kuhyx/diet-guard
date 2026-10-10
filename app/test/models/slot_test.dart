/// Tests for `models/slot.dart`, in minutes of day.
///
/// Mirrors `diet_guard/tests/test_slots.py`, `test_slots_nearest.py` and
/// `test_slot_wire.py`; the exhaustive cross-language edges live in the shared
/// fixture (`meal_schedule_vectors_test.dart`).
library;

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _at(int hour, [int minute = 0]) => DateTime(2026, 6, 22, hour, minute);

MealSchedule _s(int first, int last, int count) =>
    MealSchedule(firstMinute: first, lastMinute: last, count: count);

void main() {
  test('minuteOfDay counts minutes and ignores seconds', () {
    expect(minuteOfDay(DateTime(2026, 6, 22, 7, 15, 59)), 435);
    expect(minuteOfDay(_at(23, 59)), 1439);
  });

  test('daySlots returns the four default slots', () {
    expect(daySlots(kDefaultSchedule), [480, 720, 960, 1200]);
  });

  group('withinEnforcementWindow', () {
    test('false at 07:59, true at 08:00', () {
      expect(withinEnforcementWindow(_at(7, 59), kDefaultSchedule), isFalse);
      expect(withinEnforcementWindow(_at(8), kDefaultSchedule), isTrue);
    });

    test('true at 21:59, false at the 22:00 cutoff', () {
      expect(withinEnforcementWindow(_at(21, 59), kDefaultSchedule), isTrue);
      expect(withinEnforcementWindow(_at(22), kDefaultSchedule), isFalse);
    });

    test('a 07:15 breakfast opens the window at 07:15', () {
      final schedule = _s(435, 1140, 5);
      expect(withinEnforcementWindow(_at(7, 14), schedule), isFalse);
      expect(withinEnforcementWindow(_at(7, 15), schedule), isTrue);
    });
  });

  group('elapsedSlots', () {
    test('empty outside the enforcement window', () {
      expect(elapsedSlots(_at(23), kDefaultSchedule), isEmpty);
      expect(elapsedSlots(_at(7, 59), kDefaultSchedule), isEmpty);
    });

    test('grows through the day', () {
      expect(elapsedSlots(_at(8), kDefaultSchedule), [480]);
      expect(elapsedSlots(_at(15, 59), kDefaultSchedule), [480, 720]);
      expect(elapsedSlots(_at(21), kDefaultSchedule), [480, 720, 960, 1200]);
    });

    test('a slot opens on its minute', () {
      final schedule = _s(435, 1140, 5);
      expect(elapsedSlots(_at(10, 14), schedule), [435]);
      expect(elapsedSlots(_at(10, 15), schedule), [435, 615]);
    });
  });

  test('missingSlots excludes logged slots', () {
    expect(missingSlots(_at(17), {480}, kDefaultSchedule), [720, 960]);
    expect(missingSlots(_at(17), {480, 720, 960}, kDefaultSchedule), isEmpty);
  });

  test('currentSlot is the latest elapsed slot, or null', () {
    expect(currentSlot(_at(6), kDefaultSchedule), isNull);
    expect(currentSlot(_at(17, 41), kDefaultSchedule), 960);
  });

  group('slotForLog', () {
    // Keep in lockstep with `diet_guard/tests/test_slots.py`'s
    // TestSlotForLog: a divergence means the PC and the phone disagree about
    // which checkpoint a meal satisfied.
    test('clamps before the window and after it', () {
      expect(slotForLog(_at(0), kDefaultSchedule), 480);
      expect(slotForLog(_at(7, 59), kDefaultSchedule), 480);
      expect(slotForLog(_at(13), kDefaultSchedule), 720);
      expect(slotForLog(_at(21, 59), kDefaultSchedule), 1200);
      expect(slotForLog(_at(22), kDefaultSchedule), 1200);
    });

    test('clamps the same way at every minute across schedules', () {
      // `test_slots.py` runs the identical sweep.
      final schedules = [
        kDefaultSchedule,
        _s(480, 1200, 5),
        _s(435, 1140, 5),
        _s(443, 1181, 4),
        _s(0, 1439, 2),
        _s(600, 840, 3),
      ];
      for (final schedule in schedules) {
        final slots = daySlots(schedule);
        for (var minute = 0; minute < 1440; minute++) {
          final attributed = slotForLog(
            _at(minute ~/ 60, minute % 60),
            schedule,
          );
          final int expected;
          if (minute < slots.first) {
            expected = slots.first;
          } else if (minute >= schedule.enforcementEndMinute) {
            expected = slots.last;
          } else {
            expected = slots.where((s) => s <= minute).last;
          }
          if (attributed != expected) fail('$schedule @ $minute: $attributed');
        }
      }
    });

    test('midnight is a real slot, not a falsy absence', () {
      final schedule = _s(0, 720, 3);
      expect(daySlots(schedule), [0, 360, 720]);
      expect(currentSlot(_at(0), schedule), 0);
      expect(slotForLog(_at(0), schedule), 0);
    });
  });

  group('nearestSlot / satisfiedSlots', () {
    test('an exact halfway goes to the earlier slot', () {
      expect(nearestSlot(600, kDefaultSchedule), 480);
      expect(nearestSlot(601, kDefaultSchedule), 720);
    });

    test('outside the window clamps to the ends', () {
      expect(nearestSlot(-60, kDefaultSchedule), 480);
      expect(nearestSlot(1800, kDefaultSchedule), 1200);
    });

    test('meals logged at 07:00 and 10:00 survive a move to 07:15', () {
      expect(satisfiedSlots([420, 600], _s(435, 1140, 5)), {435, 615});
    });

    test('two meals on one slot satisfy only that slot', () {
      expect(satisfiedSlots([480, 540], kDefaultSchedule), {480});
      expect(satisfiedSlots(const [], kDefaultSchedule), isEmpty);
    });
  });

  group('slotFields / entrySlotMinute', () {
    test('a whole hour is byte-identical to the old format', () {
      expect(slotFields(480), {'slot': 8});
      expect(slotFields(435), {'slot': 7, 'slot_min': 435});
    });

    test('a minute outside the day is refused', () {
      expect(() => slotFields(-1), throwsArgumentError);
      expect(() => slotFields(1440), throwsArgumentError);
    });

    test('slot_min wins; legacy slot is an hour; bools are not ints', () {
      expect(entrySlotMinute({'slot': 8}), 480);
      expect(entrySlotMinute({'slot': 5, 'slot_min': 0}), 0);
      expect(entrySlotMinute({'slot': 8, 'slot_min': true}), 480);
      expect(entrySlotMinute({'slot': true}), isNull);
      expect(entrySlotMinute({}), isNull);
    });
  });

  test('slotLabel zero-pads and wraps into the day', () {
    expect(slotLabel(435), '07:15');
    expect(slotLabel(5), '00:05');
    expect(slotLabel(1200), '20:00');
    expect(slotLabel(1440), '00:00');
    expect(slotLabel(-15), '23:45');
  });
}
