import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/meal_component.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _manual = Nutrition(
  kcal: 150,
  proteinG: 5,
  carbsG: 20,
  fatG: 3,
  grams: 50,
  source: 'manual',
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_test_');
    LogStorageService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  group('readLog', () {
    test('returns an empty log when no file exists yet', () async {
      expect(await LogStorageService.instance.readLog(), isEmpty);
    });

    test('returns an empty log for unparsable JSON', () async {
      final file = File('${tempDir.path}/food_log.json');
      await file.writeAsString('not json');
      expect(await LogStorageService.instance.readLog(), isEmpty);
    });

    test('returns an empty log when the JSON root is not a map', () async {
      final file = File('${tempDir.path}/food_log.json');
      await file.writeAsString('[]');
      expect(await LogStorageService.instance.readLog(), isEmpty);
    });

    test('skips a date key whose value is not a list', () async {
      final file = File('${tempDir.path}/food_log.json');
      await file.writeAsString('{"2026-06-22": "not a list"}');
      expect(await LogStorageService.instance.readLog(), isEmpty);
    });
  });

  group('logMeal', () {
    test('assigns a fresh id and never an hmac', () async {
      final entry = await LogStorageService.instance.logMeal(
        'toast',
        _manual,
        slot: 8,
      );
      expect(entry.id, isNotEmpty);
      expect(entry.hmac, isNull);
      expect(entry.slot, 8);
      expect(entry.desc, 'toast');
    });

    test('persists components when given', () async {
      const components = [
        MealComponent(
          name: 'bread',
          kcal: 100,
          proteinG: 3,
          carbsG: 18,
          fatG: 1,
          grams: 40,
        ),
      ];
      final entry = await LogStorageService.instance.logMeal(
        'toast meal',
        _manual,
        components: components,
      );
      expect(entry.components, hasLength(1));
      final reloaded = await LogStorageService.instance.todayEntries();
      expect(reloaded.single.components!.single.name, 'bread');
    });

    test('two logged meals both persist under today\'s date key', () async {
      await LogStorageService.instance.logMeal('a', _manual);
      await LogStorageService.instance.logMeal('b', _manual);
      final entries = await LogStorageService.instance.todayEntries();
      expect(entries, hasLength(2));
    });
  });

  group('undoLastToday', () {
    test('returns null when today has no entries', () async {
      expect(await LogStorageService.instance.undoLastToday(), isNull);
    });

    test('tombstones the most recent entry in place', () async {
      await LogStorageService.instance.logMeal('first', _manual);
      final second = await LogStorageService.instance.logMeal(
        'second',
        _manual,
      );
      final undone = await LogStorageService.instance.undoLastToday();
      expect(undone!.id, second.id);
      expect(undone.deleted, isTrue);
    });

    test('tombstoned entries are excluded from todayEntries', () async {
      await LogStorageService.instance.logMeal('only', _manual);
      await LogStorageService.instance.undoLastToday();
      expect(await LogStorageService.instance.todayEntries(), isEmpty);
    });

    test('never touches a previous day\'s entries', () async {
      final yesterdayKey = localDateKey(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      final yesterday = FoodEntry(
        id: 'yesterday-1',
        time: '${yesterdayKey}T08:00:00+02:00',
        desc: 'yesterday meal',
        grams: 50,
        kcal: 150,
        proteinG: 5,
        carbsG: 20,
        fatG: 3,
        source: 'manual',
      );
      await LogStorageService.instance.writeLog({
        yesterdayKey: [yesterday],
      });
      await LogStorageService.instance.logMeal('today', _manual);

      expect(await LogStorageService.instance.undoLastToday(), isNotNull);

      final log = await LogStorageService.instance.readLog();
      expect(log[yesterdayKey]!.single.deleted, isFalse);
    });

    test(
      'skips an already-tombstoned entry and undoes the one before it',
      () async {
        final first = await LogStorageService.instance.logMeal(
          'first',
          _manual,
        );
        await LogStorageService.instance.logMeal('second', _manual);
        await LogStorageService.instance.undoLastToday();
        final undoneAgain = await LogStorageService.instance.undoLastToday();
        expect(undoneAgain!.id, first.id);
        expect(await LogStorageService.instance.undoLastToday(), isNull);
      },
    );
  });

  group('todayTotalKcal', () {
    test('sums kcal across today\'s non-tombstoned entries', () async {
      await LogStorageService.instance.logMeal('a', _manual);
      await LogStorageService.instance.logMeal('b', _manual);
      expect(await LogStorageService.instance.todayTotalKcal(), 300.0);
    });

    test('excludes a tombstoned entry from the total', () async {
      await LogStorageService.instance.logMeal('a', _manual);
      await LogStorageService.instance.logMeal('b', _manual);
      await LogStorageService.instance.undoLastToday();
      expect(await LogStorageService.instance.todayTotalKcal(), 150.0);
    });
  });

  group('loggedSlotsToday', () {
    test('returns only the slots with a logged entry', () async {
      await LogStorageService.instance.logMeal('a', _manual, slot: 8);
      await LogStorageService.instance.logMeal('b', _manual);
      expect(await LogStorageService.instance.loggedSlotsToday(), {8});
    });
  });

  group('allEntriesNewestFirst', () {
    const oldest = FoodEntry(
      id: 'oldest',
      time: '2026-06-01T08:00:00+02:00',
      desc: 'oldest',
      grams: 100,
      kcal: 100,
      proteinG: 5,
      carbsG: 10,
      fatG: 2,
      source: 'manual',
    );
    const newest = FoodEntry(
      id: 'newest',
      time: '2026-06-22T20:00:00+02:00',
      desc: 'newest',
      grams: 100,
      kcal: 200,
      proteinG: 10,
      carbsG: 20,
      fatG: 4,
      source: 'manual',
    );
    const tombstoned = FoodEntry(
      id: 'gone',
      time: '2026-06-15T12:00:00+02:00',
      desc: 'undone',
      grams: 100,
      kcal: 300,
      proteinG: 1,
      carbsG: 1,
      fatG: 1,
      source: 'manual',
      deleted: true,
    );

    test(
      'sorts entries across days newest-first and drops tombstones',
      () async {
        await LogStorageService.instance.writeLog({
          '2026-06-01': [oldest],
          '2026-06-15': [tombstoned],
          '2026-06-22': [newest],
        });

        final result = await LogStorageService.instance.allEntriesNewestFirst();

        expect(result.map((e) => e.id), ['newest', 'oldest']);
      },
    );

    test('returns empty for an empty log', () async {
      expect(await LogStorageService.instance.allEntriesNewestFirst(), isEmpty);
    });
  });

  group('deleteEntry', () {
    const entry = FoodEntry(
      id: 'del-1',
      time: '2026-06-22T12:00:00+02:00',
      desc: 'to delete',
      grams: 100,
      kcal: 300,
      proteinG: 10,
      carbsG: 30,
      fatG: 5,
      source: 'manual',
    );

    test('tombstones the matching entry', () async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [entry],
      });
      await LogStorageService.instance.deleteEntry('del-1');
      final log = await LogStorageService.instance.readLog();
      expect(log['2026-06-22']!.first.deleted, isTrue);
    });

    test('silently ignores an unknown id', () async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [entry],
      });
      await LogStorageService.instance.deleteEntry('no-such-id');
      final log = await LogStorageService.instance.readLog();
      expect(log['2026-06-22']!.first.deleted, isFalse);
    });

    test('does not re-tombstone an already-deleted entry', () async {
      const deleted = FoodEntry(
        id: 'del-1',
        time: '2026-06-22T12:00:00+02:00',
        desc: 'to delete',
        grams: 100,
        kcal: 300,
        proteinG: 10,
        carbsG: 30,
        fatG: 5,
        source: 'manual',
        deleted: true,
      );
      await LogStorageService.instance.writeLog({
        '2026-06-22': [deleted],
      });
      await LogStorageService.instance.deleteEntry('del-1');
      // Still deleted, no error thrown.
      final log = await LogStorageService.instance.readLog();
      expect(log['2026-06-22']!.first.deleted, isTrue);
    });
  });

  group('updateEntry', () {
    const original = FoodEntry(
      id: 'upd-1',
      time: '2026-06-22T12:00:00+02:00',
      desc: 'original desc',
      grams: 100,
      kcal: 300,
      proteinG: 10,
      carbsG: 30,
      fatG: 5,
      source: 'manual',
    );

    const updated = FoodEntry(
      id: 'upd-1',
      time: '2026-06-22T12:00:00+02:00',
      desc: 'edited desc',
      grams: 200,
      kcal: 600,
      proteinG: 20,
      carbsG: 60,
      fatG: 10,
      source: 'manual',
    );

    test('replaces the entry by id', () async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [original],
      });
      await LogStorageService.instance.updateEntry(original, updated);
      final log = await LogStorageService.instance.readLog();
      final e = log['2026-06-22']!.first;
      expect(e.desc, 'edited desc');
      expect(e.kcal, 600);
      expect(e.proteinG, 20);
    });

    test('replaces legacy null-id entry by time+desc', () async {
      const legacy = FoodEntry(
        time: '2026-06-22T12:00:00+02:00',
        desc: 'legacy entry',
        grams: 100,
        kcal: 300,
        proteinG: 10,
        carbsG: 30,
        fatG: 5,
        source: 'food bank',
      );
      const legacyUpdated = FoodEntry(
        id: 'new-uuid',
        time: '2026-06-22T12:00:00+02:00',
        desc: 'legacy entry',
        grams: 150,
        kcal: 450,
        proteinG: 15,
        carbsG: 45,
        fatG: 8,
        source: 'food bank',
      );
      await LogStorageService.instance.writeLog({
        '2026-06-22': [legacy],
      });
      await LogStorageService.instance.updateEntry(legacy, legacyUpdated);
      final log = await LogStorageService.instance.readLog();
      final e = log['2026-06-22']!.first;
      expect(e.id, 'new-uuid');
      expect(e.kcal, 450);
    });

    test('silently does nothing when no match is found', () async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [original],
      });
      const ghost = FoodEntry(
        id: 'ghost',
        time: '2026-06-22T12:00:00+02:00',
        desc: 'ghost',
        grams: 0,
        kcal: 0,
        proteinG: 0,
        carbsG: 0,
        fatG: 0,
        source: 'manual',
      );
      await LogStorageService.instance.updateEntry(ghost, updated);
      final log = await LogStorageService.instance.readLog();
      expect(log['2026-06-22']!.first.desc, 'original desc');
    });
  });
}
