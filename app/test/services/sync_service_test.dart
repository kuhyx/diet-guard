// Mirrors `test_sync.py`'s `TestRunSync` and `TestSyncBudget` cases
// (own-id-skip, no-prior-push, non-object payload, corrupt JSON, remote
// merge, food bank rebuild, budget last-writer-wins), plus one Dart-specific
// that has no PC-side equivalent.

import 'dart:convert';
import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_service_test_support.dart';

void main() {

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_sync_test_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(
      store: FileDocumentStore(tempDir),
    );
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  test('pushes the local log when no other devices have synced', () async {
    await LogStorageService.instance.logMeal('oatmeal', manualNutrition);
    final fake = FakeGitHub();
    final merged = await runSync(fake.buildClient());

    expect(merged.values.expand((e) => e).length, 1);
    // syncLog always pushes, even an empty merged result: food_log.json,
    // budget.json, food_bank.json, food_bank_manual.json -- plus this
    // device's revision, published after the log so a peer can never cache
    // "seen rev X" against a log it never received.
    expect(fake.puts, hasLength(5));
  });
  test("skips its own device id ('phone') when listing", () async {
    final fake = FakeGitHub(
      deviceDirs: const ['pc', 'phone'],
      files: const {
        'diet-guard-sync/devices/pc/food_log.json': '{}',
        'diet-guard-sync/devices/pc/budget.json': '{}',
      },
    );
    await runSync(fake.buildClient());
    // Both the food-log and budget pulls skip "phone" (this device) and
    // only ever read "pc"'s files.
    expect(fake.fileGets, [
      'diet-guard-sync/devices/pc/food_log.json',
      'diet-guard-sync/devices/pc/budget.json',
    ]);
  });
  test('skips a device with no pushed file yet', () async {
    final fake = FakeGitHub(deviceDirs: const ['pc']);
    final merged = await runSync(fake.buildClient());
    expect(merged, isEmpty);
  });
  test('ignores a device whose pushed file is not a JSON object', () async {
    final fake = FakeGitHub(
      deviceDirs: const ['pc'],
      files: const {'diet-guard-sync/devices/pc/food_log.json': '[]'},
    );
    final merged = await runSync(fake.buildClient());
    expect(merged, isEmpty);
  });
  test('skips a device whose pushed file is corrupt json', () async {
    final fake = FakeGitHub(
      deviceDirs: const ['pc'],
      files: const {
        'diet-guard-sync/devices/pc/food_log.json': '{not valid json',
      },
    );
    final merged = await runSync(fake.buildClient());
    expect(merged, isEmpty);
  });
  test(
    "merges in a remote device's entries (old pre-migration format)",
    () async {
      final remoteLog = jsonEncode({
        '2026-06-22': [
          {
            'id': 'pc-1',
            'time': '2026-06-22T09:00:00+02:00',
            'desc': 'pc meal',
            'kcal': 400.0,
            'protein_g': 20.0,
            'carbs_g': 40.0,
            'fat_g': 10.0,
            'grams': 300.0,
            'source': 'manual',
          },
        ],
      });
      final fake = FakeGitHub(
        deviceDirs: const ['pc'],
        files: {'diet-guard-sync/devices/pc/food_log.json': remoteLog},
      );
      final merged = await runSync(fake.buildClient());
      final descs = merged.values.expand((e) => e).map((e) => e.desc).toSet();
      expect(descs, contains('pc meal'));
    },
  );
  test(
    "merges in a remote device's entries (new Record-based format)",
    () async {
      const remoteEntry = FoodEntry(
        id: 'pc-1',
        time: '2026-06-22T09:00:00+02:00',
        desc: 'pc meal',
        kcal: 400,
        proteinG: 20,
        carbsG: 40,
        fatG: 10,
        grams: 300,
        source: 'manual',
      );
      final remoteLog = jsonEncode({
        'pc-1': Record(
          id: 'pc-1',
          fields: {
            'body': (
              remoteEntry.toSyncJson(),
              Hlc.newTick('pc', wallTimeMsOverride: 0),
            ),
          },
        ).toJson(),
      });
      final fake = FakeGitHub(
        deviceDirs: const ['pc'],
        files: {'diet-guard-sync/devices/pc/food_log.json': remoteLog},
      );
      final merged = await runSync(fake.buildClient());
      final descs = merged.values.expand((e) => e).map((e) => e.desc).toSet();
      expect(descs, contains('pc meal'));
    },
  );
  test('rebuilds the food bank after merge', () async {
    await LogStorageService.instance.logMeal('oatmeal', manualNutrition);
    final fake = FakeGitHub();
    await runSync(fake.buildClient());

    final bank = await FoodBankService.instance.readBank();
    expect(bank.containsKey('oatmeal'), isTrue);
  });
  test('pushes a payload without hmac', () async {
    await LogStorageService.instance.logMeal(
      'oatmeal',
      manualNutrition,
    );
    final fake = FakeGitHub();
    await runSync(fake.buildClient());

    final pushed =
        fake.putsByPath['diet-guard-sync/devices/phone/food_log.json']!;
    final pushedText = utf8.decode(base64.decode(pushed['content'] as String));
    expect(pushedText, isNot(contains('hmac')));
  });
  test('pushes in the new Record-based wire format', () async {
    await LogStorageService.instance.logMeal('oatmeal', manualNutrition);
    final fake = FakeGitHub();
    await runSync(fake.buildClient());

    final pushed =
        fake.putsByPath['diet-guard-sync/devices/phone/food_log.json']!;
    final pushedText = utf8.decode(base64.decode(pushed['content'] as String));
    final decoded = jsonDecode(pushedText) as Map<String, dynamic>;
    final record = decoded.values.single as Map<String, dynamic>;
    expect(record, containsPair('id', isA<String>()));
    expect(record, contains('fields'));
  });
  test("reuses this device's existing sha when it has pushed before", () async {
    final fake = FakeGitHub(
      files: const {'diet-guard-sync/devices/phone/food_log.json': '{}'},
    );
    await runSync(fake.buildClient());
    expect(
      fake.putsByPath['diet-guard-sync/devices/phone/food_log.json']!['sha'],
      'f-phone',
    );
  });
}
