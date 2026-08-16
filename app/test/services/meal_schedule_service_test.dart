/// Tests for meal-schedule persistence.
///
/// Split from `meal_schedule_history_test.dart` (250-line cap); that file
/// keeps the pure parsing/derivation half. Mirrors the storage half of
/// `diet_guard/tests/test_meal_schedule_store.py`.
library;

import 'dart:convert';

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/meal_schedule_history.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store, so these tests need no plugin channel.
class _MemoryStore implements DocumentStore {
  final Map<String, String> documents = {};

  @override
  Future<String?> read(String name) async => documents[name];

  @override
  Future<void> write(String name, String contents) async {
    documents[name] = contents;
  }
}

DateTime _at(String day) => DateTime.parse('${day}T12:00:00');

void main() {
  late _MemoryStore store;

  setUp(() {
    store = _MemoryStore();
    MealScheduleService.resetForTesting(store: store);
  });

  tearDown(MealScheduleService.resetForTesting);

  group('MealScheduleService', () {
    test('current is the default before any edit', () {
      expect(MealScheduleService.current, kDefaultSchedule);
      expect(MealScheduleService.updatedAt, isNull);
    });

    test('current degrades to the default when uninitialised', () {
      MealScheduleService.resetForTesting();
      expect(MealScheduleService.current, kDefaultSchedule);
      expect(MealScheduleService.history.entries, isEmpty);
      expect(MealScheduleService.isInitialized, isFalse);
    });

    test(
      'recordChange persists, reloads, and grandfathers past days',
      () async {
        await MealScheduleService.initForTesting(store);
        await MealScheduleService.instance.recordChange(
          const MealSchedule(first: 8, last: 20, count: 5),
        );

        await MealScheduleService.initForTesting(store);
        expect(
          MealScheduleService.current,
          const MealSchedule(first: 8, last: 20, count: 5),
        );
        // The whole point of the history: a day before the edit keeps the
        // four-meal schedule it was actually judged against.
        expect(
          MealScheduleService.history.forDay('2020-01-01'),
          kDefaultSchedule,
        );
        expect(MealScheduleService.updatedAt, isNotNull);
      },
    );

    test('a corrupt document degrades to the default', () async {
      store.documents[MealScheduleService.documentName] = '{not json';
      await MealScheduleService.initForTesting(store);
      expect(MealScheduleService.current, kDefaultSchedule);
    });

    test('an absent document loads as no history', () async {
      await MealScheduleService.initForTesting(store);
      expect(MealScheduleService.history.entries, isEmpty);
    });

    test(
      'updatedAt stays null when the stored stamp is not a string',
      () async {
        store.documents[MealScheduleService.documentName] = jsonEncode({
          'v': 1,
          'e': <String, Object?>{},
          't': 7,
        });
        await MealScheduleService.initForTesting(store);
        expect(MealScheduleService.updatedAt, isNull);
      },
    );

    test(
      'applyMerged replaces the history but ignores an empty merge',
      () async {
        await MealScheduleService.initForTesting(store);
        await MealScheduleService.instance.recordChange(
          const MealSchedule(first: 8, last: 20, count: 5),
        );

        // A pre-feature peer contributes no `sched:` fields; writing that back
        // would discard this device's own history.
        await MealScheduleService.instance.applyMerged(const []);
        expect(
          MealScheduleService.current,
          const MealSchedule(first: 8, last: 20, count: 5),
        );

        final stamp = DateTime.parse('2026-08-16T09:00:00.000');
        await MealScheduleService.instance.applyMerged([
          ScheduleEntry(
            effectiveFrom: kScheduleEpochDay,
            schedule: const MealSchedule(first: 7, last: 19, count: 3),
            editedAt: stamp.toIso8601String(),
          ),
        ], updatedAt: stamp);
        expect(
          MealScheduleService.current,
          const MealSchedule(first: 7, last: 19, count: 3),
        );
        // The winner's stamp is kept verbatim, so re-syncing is idempotent.
        expect(MealScheduleService.updatedAt, stamp);
      },
    );

    test('the stored document is plain readable JSON', () async {
      await MealScheduleService.initForTesting(store);
      await MealScheduleService.instance.recordChange(
        const MealSchedule(first: 8, last: 20, count: 5),
        when: _at('2026-08-16'),
      );
      final decoded =
          jsonDecode(store.documents[MealScheduleService.documentName]!)
              as Map<String, Object?>;
      expect(decoded['v'], 1);
      expect((decoded['e']! as Map).keys, contains('2026-08-16'));
    });
  });
}
