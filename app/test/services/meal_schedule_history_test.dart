/// Tests for the pure meal-schedule history: parsing, encoding, forDay,
/// upsert and seeding.
///
/// Split from `meal_schedule_service_test.dart` (250-line cap); that file
/// keeps the persistence half. Mirrors
/// `diet_guard/tests/test_meal_schedule_store.py`.
library;

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/services/meal_schedule_history.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _at(String day) => DateTime.parse('${day}T12:00:00');

void main() {
  group('scheduleEntryFromJson', () {
    test('round trips', () {
      const entry = ScheduleEntry(
        effectiveFrom: '2026-08-16',
        schedule: MealSchedule(first: 8, last: 20, count: 5),
        editedAt: '2026-08-16T12:00:00.000',
      );
      expect(
        scheduleEntryFromJson('2026-08-16', scheduleEntryToJson(entry)),
        entry,
      );
    });

    test('normalizes on the way in', () {
      final entry = scheduleEntryFromJson('2026-08-16', {
        'f': 8,
        'l': 20,
        'n': 99,
      });
      expect(entry!.schedule, const MealSchedule(first: 8, last: 20, count: 6));
    });

    test('falls back to the epoch when the stamp is missing', () {
      final entry = scheduleEntryFromJson('2026-08-16', {
        'f': 8,
        'l': 20,
        'n': 4,
      });
      expect(entry!.editedAt, '1970-01-01T00:00:00.000Z');
    });

    test('rejects a non-mapping', () {
      expect(scheduleEntryFromJson('2026-08-16', 'nonsense'), isNull);
    });

    test('rejects non-integer fields', () {
      expect(
        scheduleEntryFromJson('2026-08-16', {'f': '8', 'l': 20, 'n': 4}),
        isNull,
      );
    });
  });

  group('MealScheduleHistory', () {
    test('parse degrades on anything unreadable', () {
      expect(MealScheduleHistory.parse('nonsense'), isEmpty);
      expect(MealScheduleHistory.parse({'e': 'nonsense'}), isEmpty);
      expect(MealScheduleHistory.parse(const <String, Object?>{}), isEmpty);
    });

    test('parse skips only the bad entry', () {
      final parsed = MealScheduleHistory.parse(const {
        'e': {
          '2026-01-01': {'f': 8, 'l': 20, 'n': 4},
          '2026-02-01': 7,
        },
      });
      expect(parsed.map((e) => e.effectiveFrom), ['2026-01-01']);
    });

    test('parse ignores a non-string key', () {
      final parsed = MealScheduleHistory.parse(const {
        'e': {
          7: {'f': 8, 'l': 20, 'n': 4},
        },
      });
      expect(parsed, isEmpty);
    });

    test('forDay defaults when the history is silent', () {
      final history = MealScheduleHistory(const [
        ScheduleEntry(
          effectiveFrom: '2026-08-16',
          schedule: MealSchedule(first: 8, last: 20, count: 5),
          editedAt: 't',
        ),
      ]);
      expect(history.forDay('2026-08-15'), kDefaultSchedule);
    });

    test('forDay uses the newest applicable entry', () {
      final history = MealScheduleHistory(const [
        ScheduleEntry(
          effectiveFrom: '2026-08-16',
          schedule: MealSchedule(first: 8, last: 20, count: 5),
          editedAt: 't1',
        ),
        ScheduleEntry(
          effectiveFrom: '2026-01-01',
          schedule: kDefaultSchedule,
          editedAt: 't0',
        ),
      ]);
      expect(
        history.forDay('2026-08-16'),
        const MealSchedule(first: 8, last: 20, count: 5),
      );
      expect(history.forDay('2026-05-01'), kDefaultSchedule);
    });

    test('upsert replaces a same-day re-edit', () {
      final once = MealScheduleHistory.empty.upsert(
        const MealSchedule(first: 8, last: 20, count: 5),
        when: _at('2026-08-16'),
      );
      final twice = once.upsert(
        const MealSchedule(first: 9, last: 21, count: 3),
        when: _at('2026-08-16'),
      );
      expect(twice.entries, hasLength(1));
      expect(
        twice.entries.single.schedule,
        const MealSchedule(first: 9, last: 21, count: 3),
      );
    });

    test('upsert defaults to now', () {
      final history = MealScheduleHistory.empty.upsert(
        const MealSchedule(first: 8, last: 20, count: 5),
      );
      expect(history.entries, hasLength(1));
    });

    test('seedDefault pins the default at the epoch and is idempotent', () {
      final seeded = MealScheduleHistory.empty.seedDefault();
      expect(seeded.entries.first.effectiveFrom, kScheduleEpochDay);
      expect(seeded.entries.first.schedule, kDefaultSchedule);
      expect(seeded.seedDefault().entries, hasLength(1));
    });
  });
}
