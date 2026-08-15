import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
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
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    await tempDir.delete(recursive: true);
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
}
