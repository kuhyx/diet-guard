import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/meal_component.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

FoodEntry _entry({
  required String id,
  required String time,
  required String desc,
  double kcal = 100,
  List<MealComponent>? components,
  bool deleted = false,
}) => FoodEntry(
  id: id,
  time: time,
  desc: desc,
  grams: 100,
  kcal: kcal,
  proteinG: 1,
  carbsG: 1,
  fatG: 1,
  source: components != null ? 'meal' : 'manual',
  components: components,
  deleted: deleted,
);

void main() {
  group('FoodBankService.rebuild (pure)', () {
    test('upserts a single-food entry by normalized name', () {
      final log = {
        '2026-06-22': [
          _entry(id: '1', time: '2026-06-22T08:00:00+02:00', desc: 'Toast'),
        ],
      };
      final bank = FoodBankService.rebuild(log);
      expect(bank['toast']!.desc, 'Toast');
      expect(bank['toast']!.count, 1);
    });

    test('increments count and keeps the latest macros on repeat', () {
      final log = {
        '2026-06-22': [
          _entry(
            id: '1',
            time: '2026-06-22T08:00:00+02:00',
            desc: 'toast',
            kcal: 100,
          ),
          _entry(
            id: '2',
            time: '2026-06-22T12:00:00+02:00',
            desc: 'toast',
            kcal: 120,
          ),
        ],
      };
      final bank = FoodBankService.rebuild(log);
      expect(bank['toast']!.count, 2);
      expect(bank['toast']!.kcal, 120);
    });

    test('skips a tombstoned entry entirely', () {
      final log = {
        '2026-06-22': [
          _entry(
            id: '1',
            time: '2026-06-22T08:00:00+02:00',
            desc: 'toast',
            deleted: true,
          ),
        ],
      };
      expect(FoodBankService.rebuild(log), isEmpty);
    });

    test('records a composite entry\'s components and total separately', () {
      const components = [
        MealComponent(
          name: 'rice',
          kcal: 200,
          proteinG: 4,
          carbsG: 44,
          fatG: 1,
          grams: 150,
        ),
      ];
      final log = {
        '2026-06-22': [
          _entry(
            id: '1',
            time: '2026-06-22T20:00:00+02:00',
            desc: 'dinner',
            kcal: 200,
            components: components,
          ),
        ],
      };
      final bank = FoodBankService.rebuild(log);
      expect(bank['rice'], isNotNull);
      expect(bank['dinner']!.components, ['rice']);
    });

    test('orders replay by time then id so two devices converge', () {
      final logA = {
        '2026-06-22': [
          _entry(id: 'b', time: '2026-06-22T08:00:00+02:00', desc: 'x'),
          _entry(id: 'a', time: '2026-06-22T08:00:00+02:00', desc: 'x'),
        ],
      };
      final logB = {
        '2026-06-22': [
          _entry(id: 'a', time: '2026-06-22T08:00:00+02:00', desc: 'x'),
          _entry(id: 'b', time: '2026-06-22T08:00:00+02:00', desc: 'x'),
        ],
      };
      expect(
        FoodBankService.rebuild(logA)['x']!.count,
        FoodBankService.rebuild(logB)['x']!.count,
      );
    });
  });

  group('FoodBankService search/persistence', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('diet_guard_bank_');
      FoodBankService.resetForTesting(testDir: tempDir);
      LogStorageService.resetForTesting(testDir: tempDir);
    });

    tearDown(() async {
      FoodBankService.resetForTesting();
      LogStorageService.resetForTesting();
      await tempDir.delete(recursive: true);
    });

    test('readBank returns empty map when no file exists', () async {
      expect(await FoodBankService.instance.readBank(), isEmpty);
    });

    test('rebuildAndPersist writes the bank to disk', () async {
      final log = {
        '2026-06-22': [
          _entry(id: '1', time: '2026-06-22T08:00:00+02:00', desc: 'egg'),
        ],
      };
      await FoodBankService.instance.rebuildAndPersist(log);
      final reread = await FoodBankService.instance.readBank();
      expect(reread['egg'], isNotNull);
    });

    test('search ranks an exact substring match above a fuzzy one', () async {
      final log = {
        '2026-06-22': [
          _entry(id: '1', time: '2026-06-22T08:00:00+02:00', desc: 'banana'),
          _entry(id: '2', time: '2026-06-22T08:01:00+02:00', desc: 'banama'),
        ],
      };
      await FoodBankService.instance.rebuildAndPersist(log);
      final results = await FoodBankService.instance.search('banana');
      expect(results.first.name, 'banana');
    });

    test('empty query returns the most-logged foods first', () async {
      final log = {
        '2026-06-22': [
          _entry(id: '1', time: '2026-06-22T08:00:00+02:00', desc: 'rare'),
          _entry(id: '2', time: '2026-06-22T08:01:00+02:00', desc: 'common'),
          _entry(id: '3', time: '2026-06-22T08:02:00+02:00', desc: 'common'),
        ],
      };
      await FoodBankService.instance.rebuildAndPersist(log);
      final results = await FoodBankService.instance.search('');
      expect(results.first.name, 'common');
    });
  });
}
