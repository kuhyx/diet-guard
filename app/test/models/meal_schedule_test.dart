/// Tests for the pure meal-schedule derivation.
///
/// The cross-language exact values live in the shared fixture
/// `tests/fixtures/meal_schedule_vectors.json`, asserted by
/// `meal_schedule_vectors_test.dart` (and by its Python mirror). This file
/// holds the properties: the grid sweep, the hour-formula regression and the
/// clamps a human should read without opening the fixture. The sweeps are
/// duplicated loop-for-loop in `diet_guard/tests/test_meal_schedule.py`.
library;

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

const int _h = 60;

/// The pre-minute whole-hour derivation, converted to minutes.
List<int> _oldHourSlots(int first, int last, int count) {
  final span = last - first;
  final divisions = count - 1;
  return [
    for (var index = 0; index < count; index++)
      (first + (index * span + divisions ~/ 2) ~/ divisions) * _h,
  ];
}

bool _strictlyAscending(List<int> slots) {
  for (var i = 1; i < slots.length; i++) {
    if (slots[i - 1] >= slots[i]) return false;
  }
  return true;
}

MealSchedule _s(int first, int last, int count) =>
    MealSchedule(firstMinute: first, lastMinute: last, count: count);

void main() {
  group('slots', () {
    test('the default is the historical schedule', () {
      expect(kDefaultSchedule.slots(), [480, 720, 960, 1200]);
    });

    // Upgrading must not move a checkpoint for the schedules people actually
    // have, or every existing hour-tagged entry would satisfy a neighbour.
    for (final (first, last, count) in const [
      (8, 20, 4),
      (8, 20, 5),
      (7, 19, 5),
    ]) {
      test('$first-$last x$count matches the old hour formula', () {
        expect(
          _s(first * _h, last * _h, count).slots(),
          _oldHourSlots(first, last, count),
        );
      });
    }

    test('off-grid endpoints are exact; only the interior snaps', () {
      final slots = _s(443, 1181, 5).slots();
      expect(slots.first, 443);
      expect(slots.last, 1181);
      for (final slot in slots.sublist(1, slots.length - 1)) {
        expect(slot % kSlotGridMinutes, 0);
      }
    });

    test("the user's quarter-hour schedule", () {
      expect(_s(435, 1140, 5).slots(), [435, 615, 795, 960, 1140]);
    });
  });

  group('normalized', () {
    final cases = <(MealSchedule, MealSchedule)>[
      (_s(480, 1200, 99), _s(480, 1200, kMaxMealCount)),
      (_s(480, 1200, 0), _s(480, 1200, kMinMealCount)),
      (_s(-5, 1200, 4), _s(0, 1200, 4)),
      (_s(480, 9999, 4), _s(480, 1439, 4)),
      // last <= first is pulled forward to leave one grid step of window.
      (_s(720, 720, 4), _s(720, 735, 2)),
      (_s(720, 3, 4), _s(720, 735, 2)),
      // first cannot sit in the final grid step, or no window remains.
      (_s(1439, 1439, 2), _s(1424, 1439, 2)),
      // Count is capped by the grid: 60 minutes hold 5 quarter-hour marks.
      (_s(480, 540, 6), _s(480, 540, 5)),
    ];
    for (final (input, expected) in cases) {
      test('$input clamps to $expected', () {
        expect(input.normalized(), expected);
      });
    }

    test('garbage still yields usable slots', () {
      expect(_s(9999, -5, 999).slots(), [1424, 1439]);
    });
  });

  group('enforcementEndMinute', () {
    test('the default keeps the historical 22:00 cutoff', () {
      expect(kDefaultSchedule.enforcementEndMinute, 22 * _h);
    });

    test('the tail follows the last meal, to the minute', () {
      expect(_s(480, 1095, 4).enforcementEndMinute, 1215);
    });

    test('is clamped to the end of the day', () {
      // An unclamped 1380 + 120 = 1500 would make `minute < cutoff`
      // vacuously true, so the enforcement window would never close.
      expect(_s(480, 1380, 4).enforcementEndMinute, kMinutesPerDay);
    });

    test('follows the normalised last meal', () {
      final schedule = _s(720, 3, 4);
      expect(schedule.enforcementEndMinute, schedule.slots().last + 120);
    });
  });

  group('wire', () {
    test('a whole-hour schedule encodes exactly as before', () {
      expect(scheduleToWire(kDefaultSchedule), {'f': 8, 'l': 20, 'n': 4});
    });

    test('off-hour endpoints add minute fields', () {
      expect(scheduleToWire(_s(435, 1181, 5)), {
        'f': 7,
        'l': 19,
        'n': 5,
        'fm': 435,
        'lm': 1181,
      });
    });

    test('unusable values decode to null', () {
      expect(scheduleFromWire({'f': true, 'l': 20, 'n': 4}), isNull);
      expect(scheduleFromWire('not a map'), isNull);
    });
  });

  test('grid sweep yields ascending slots with exact endpoints', () {
    // The Python mirror runs the identical loop. A wire round trip rides
    // along, because it is the same sweep's worth of schedules. Plain checks
    // with `fail` rather than `expect` per cell keep 46k cells fast.
    for (var first = 0; first < kMinutesPerDay; first += kSlotGridMinutes) {
      for (var last = 0; last < kMinutesPerDay; last += kSlotGridMinutes) {
        for (var count = kMinMealCount; count <= kMaxMealCount; count++) {
          final schedule = _s(first, last, count);
          final normalized = schedule.normalized();
          final slots = schedule.slots();
          final ok =
              slots.first == normalized.firstMinute &&
              slots.last == normalized.lastMinute &&
              slots.length == normalized.count &&
              _strictlyAscending(slots) &&
              slots.first >= 0 &&
              slots.last < kMinutesPerDay &&
              scheduleFromWire(scheduleToWire(schedule)) == normalized;
          if (!ok) fail('$schedule derived $slots');
        }
      }
    }
  });

  test('off-grid sweep stays strictly ascending', () {
    for (var first = 0; first < 120; first += 7) {
      for (var width = 15; width < 200; width += 11) {
        for (var count = kMinMealCount; count <= kMaxMealCount; count++) {
          final slots = _s(first, first + width, count).slots();
          if (!_strictlyAscending(slots)) fail('$first+$width x$count: $slots');
        }
      }
    }
  });
}
