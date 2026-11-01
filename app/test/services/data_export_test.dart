// Export -> import must be lossless, idempotent and merge-only.

import 'dart:convert';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/body_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/data_export.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_test_support.dart';

/// Points every service at a fresh in-memory store.
Future<MemoryDocStore> _bindFreshStore() async {
  final store = MemoryDocStore();
  LogStorageService.resetForTesting(store: store);
  FoodBankService.resetForTesting(store: store);
  await AppSettingsService.initForTesting(store);
  await BudgetHistoryService.initForTesting(store);
  await MealScheduleService.initForTesting(store);
  await BodyService.initForTesting(store);
  return store;
}

FoodEntry _entry(
  String? id,
  String time,
  String desc, {
  bool deleted = false,
}) => FoodEntry(
  id: id,
  time: time,
  desc: desc,
  grams: 100,
  kcal: 250,
  proteinG: 10,
  carbsG: 30,
  fatG: 8,
  source: 'manual',
  slotMinute: 480,
  deleted: deleted,
);

/// Seeds one of every document type, incl. a tombstone and a legacy entry.
Future<void> _seed({String suffix = ''}) async {
  final log = {
    '2026-10-01': [
      _entry('id-a$suffix', '2026-10-01T08:05:00', 'oats$suffix'),
      _entry('id-b$suffix', '2026-10-01T12:10:00', 'soup', deleted: true),
      _entry(null, '2026-10-01T16:00:00', 'legacy apple$suffix'),
    ],
  };
  await LogStorageService.instance.writeLog(log);
  await FoodBankService.instance.rebuildAndPersist(log);
  await FoodBankService.instance.applyMergedManualBank({
    'skyr$suffix': FoodBankRecord(
      desc: 'skyr$suffix',
      kcal: 60,
      proteinG: 11,
      carbsG: 4,
      fatG: 0,
      grams: 100,
      count: 1,
      editedAt: '2026-10-02T09:00:00',
    ),
  });
  await AppSettingsService.instance.saveDailyKcalGoal(1900);
  await MealScheduleService.instance.recordChange(
    const MealSchedule(firstMinute: 450, lastMinute: 1230, count: 5),
    when: DateTime(2026, 10, 3, 10),
  );
  await BodyService.instance.setWeight(
    '2026-10-04',
    81.5,
    now: DateTime(2026, 10, 4, 7),
  );
}

Map<String, dynamic> _documents(String export) =>
    (jsonDecode(export) as Map<String, dynamic>)['documents']
        as Map<String, dynamic>;

void main() {
  test(
    'round trip: import into an empty store reproduces the export',
    () async {
      await _bindFreshStore();
      await _seed();
      final original = await exportAllData();
      final docs = _documents(original);
      for (final key in ['food_log', 'food_bank', 'food_bank_manual']) {
        expect(docs[key], isNotEmpty, reason: key);
      }
      expect(docs['budget'], isNotEmpty);
      expect(docs['body'], isNotEmpty);

      await _bindFreshStore();
      await importAllData(original);
      expect(_documents(await exportAllData()), _documents(original));
    },
  );

  test('importing the same file twice equals importing it once', () async {
    await _bindFreshStore();
    await _seed();
    final file = await exportAllData();

    final store = await _bindFreshStore();
    await importAllData(file);
    final once = Map.of(store.documents);
    await importAllData(file);
    expect(store.documents, once);
  });

  test('import into a non-empty store keeps the existing records', () async {
    await _bindFreshStore();
    await _seed(suffix: '-file');
    final file = await exportAllData();

    await _bindFreshStore();
    await _seed(suffix: '-local');
    final before = _documents(await exportAllData());
    await importAllData(file);
    final after = _documents(await exportAllData());

    for (final key in ['food_log', 'food_bank', 'food_bank_manual']) {
      final kept = (after[key] as Map).keys.toSet();
      expect(kept, containsAll((before[key] as Map).keys), reason: key);
      expect(kept, containsAll((_documents(file)[key] as Map).keys));
    }
    final descs = (await LogStorageService.instance.allEntriesNewestFirst())
        .map((e) => e.desc);
    expect(
      descs,
      containsAll(['oats-local', 'oats-file', 'legacy apple-file']),
    );
  });

  test('import keeps food-bank counts the log cannot rebuild', () async {
    await _bindFreshStore();
    await _seed(suffix: '-file');
    final file = await exportAllData();

    await _bindFreshStore();
    await FoodBankService.instance.writeBank({
      'pierogi': const FoodBankRecord(
        desc: 'pierogi',
        kcal: 300,
        proteinG: 9,
        carbsG: 40,
        fatG: 11,
        grams: 200,
        count: 7,
      ),
    });
    await importAllData(file);
    final bank = await FoodBankService.instance.readBank();
    expect(bank['pierogi']?.count, 7);
  });

  test('rejects a file that is not a diet_guard export', () async {
    await _bindFreshStore();
    expect(() => importAllData('{"days": []}'), throwsFormatException);
    expect(() => importAllData('not json'), throwsFormatException);
  });
}
