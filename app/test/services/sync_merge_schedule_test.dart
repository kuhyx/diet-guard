/// Tests for the meal-schedule half of the shared `budget` CRDT record.
///
/// Mirrors `diet_guard/tests/test_sync_merge_schedule.py`.
library;

import 'dart:convert';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/services/meal_schedule_history.dart';
import 'package:diet_guard_app/services/sync_merge_budget.dart';
import 'package:diet_guard_app/services/sync_merge_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

const _record = <String, dynamic>{
  'v': 2,
  'b': 2200,
  't': '2026-08-16T10:00:00+02:00',
};

ScheduleEntry _entry(String day, MealSchedule schedule, String when) =>
    ScheduleEntry(effectiveFrom: day, schedule: schedule, editedAt: when);

String _wire(Log log) => jsonEncode({
  for (final entry in log.entries) entry.key: entry.value.toJson(),
});

void main() {
  group('scheduleFields', () {
    test('no entries contributes nothing', () {
      // A device that never edited a schedule cannot outrank a peer.
      expect(scheduleFields(const []), isEmpty);
    });

    test('one field per entry', () {
      final fields = scheduleFields([
        _entry(
          '2026-08-16',
          const MealSchedule(first: 8, last: 20, count: 5),
          '2026-08-16T10:00:00+02:00',
        ),
      ]);
      expect(fields.keys, ['${scheduleFieldPrefix}2026-08-16']);
      expect(fields['${scheduleFieldPrefix}2026-08-16']!.$1, {
        'f': 8,
        'l': 20,
        'n': 5,
      });
    });

    test('the Hlc is deterministic', () {
      final entry = _entry(
        '2026-08-16',
        const MealSchedule(first: 8, last: 20, count: 5),
        '2026-08-16T10:00:00+02:00',
      );
      expect(
        scheduleHlc(entry).wallTimeMs,
        scheduleHlc(entry).wallTimeMs,
      );
    });

    test('an unparsable timestamp falls back to the epoch', () {
      final entry = _entry(
        '2026-08-16',
        const MealSchedule(first: 8, last: 20, count: 5),
        'not-a-timestamp',
      );
      expect(scheduleHlc(entry).wallTimeMs, 0);
    });
  });

  group('logToScheduleHistory', () {
    test('an absent record yields nothing', () {
      expect(logToScheduleHistory(const {}), isEmpty);
    });

    test('round trips', () {
      final back = logToScheduleHistory(
        budgetToLog(_record, const [], [
          _entry(
            '2026-08-16',
            const MealSchedule(first: 8, last: 20, count: 5),
            '2026-08-16T10:00:00+02:00',
          ),
        ]),
      );
      expect(back, hasLength(1));
      expect(back.single.effectiveFrom, '2026-08-16');
      expect(
        back.single.schedule,
        const MealSchedule(first: 8, last: 20, count: 5),
      );
    });

    test("normalizes a peer's out-of-range schedule", () {
      final log = budgetToLog(_record);
      final record = log[budgetRecordId]!;
      final hlc = record.fields.values.first.$2;
      record.fields['${scheduleFieldPrefix}2026-08-16'] = (
        {'f': 8, 'l': 20, 'n': 99},
        hlc,
      );
      expect(
        logToScheduleHistory(log).single.schedule,
        const MealSchedule(first: 8, last: 20, count: 6),
      );
    });

    test('skips malformed values', () {
      final log = budgetToLog(_record);
      final record = log[budgetRecordId]!;
      final hlc = record.fields.values.first.$2;
      record.fields['${scheduleFieldPrefix}2026-01-01'] = (7, hlc);
      record.fields['${scheduleFieldPrefix}2026-02-01'] = ({'f': '8'}, hlc);
      expect(logToScheduleHistory(log), isEmpty);
    });
  });

  group('cross-device merge', () {
    test('a pre-feature peer relays the schedule untouched', () {
      // `mergeRecord` is per-field LWW over the *union* of field names, and
      // both devices push the merged record, so a budget-only push merges the
      // fields in rather than clobbering them. This is what makes the feature
      // shippable without a coordinated release.
      final ours = budgetToLog(_record, const [], [
        _entry('1970-01-01', kDefaultSchedule, '1970-01-01T00:00:00.000Z'),
        _entry(
          '2026-08-16',
          const MealSchedule(first: 8, last: 20, count: 5),
          '2026-08-16T10:00:00+02:00',
        ),
      ]);
      final peer = budgetToLog(const <String, dynamic>{
        'v': 2,
        'b': 1900,
        't': '2026-08-16T11:00:00+02:00',
      });

      final merged = mergeLogs(parseRemoteBudget(_wire(ours)), peer);

      expect(logToScheduleHistory(merged).map((e) => e.schedule), [
        kDefaultSchedule,
        const MealSchedule(first: 8, last: 20, count: 5),
      ]);
    });

    test('the newer edit wins per day', () {
      final older = budgetToLog(_record, const [], [
        _entry(
          '2026-08-16',
          const MealSchedule(first: 8, last: 20, count: 5),
          '2026-08-16T10:00:00+02:00',
        ),
      ]);
      final newer = budgetToLog(_record, const [], [
        _entry(
          '2026-08-16',
          const MealSchedule(first: 7, last: 21, count: 3),
          '2026-08-16T18:00:00+02:00',
        ),
      ]);

      final merged = mergeLogs(parseRemoteBudget(_wire(older)), newer);
      expect(
        logToScheduleHistory(merged).single.schedule,
        const MealSchedule(first: 7, last: 21, count: 3),
      );
    });
  });
}
