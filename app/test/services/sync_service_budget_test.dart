// Mirrors `test_sync.py`'s `TestRunSync` and `TestSyncBudget` cases
// (own-id-skip, no-prior-push, non-object payload, corrupt JSON, remote
// merge, food bank rebuild, budget last-writer-wins), plus one Dart-specific
// that has no PC-side equivalent.

import 'dart:convert';
import 'dart:io';

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

  group('budget sync', () {
    test(
      'pushes the local budget when no other devices have synced',
      () async {
        await AppSettingsService.instance.saveDailyKcalGoal(2000);
        final fake = FakeGitHub();
        await runSync(fake.buildClient());

        expect(
          fake.putsByPath.containsKey(
            'diet-guard-sync/devices/phone/budget.json',
          ),
          isTrue,
        );
      },
    );

    test('remote-only budget is adopted locally', () async {
      final remoteJson = remoteBudgetJson(
        kcal: 1800,
        t: '2026-01-01T09:00:00',
      );
      final fake = FakeGitHub(
        deviceDirs: const ['pc'],
        files: {'diet-guard-sync/devices/pc/budget.json': remoteJson},
      );
      await runSync(fake.buildClient());
      expect(AppSettingsService.dailyKcalGoal, 1800);
    });

    test('a local edit later than a remote edit wins', () async {
      await AppSettingsService.instance.saveDailyKcalGoal(1500); // now
      final remoteJson = remoteBudgetJson(
        kcal: 1800,
        t: '2020-01-01T09:00:00',
      );
      final fake = FakeGitHub(
        deviceDirs: const ['pc'],
        files: {'diet-guard-sync/devices/pc/budget.json': remoteJson},
      );
      await runSync(fake.buildClient());
      expect(AppSettingsService.dailyKcalGoal, 1500);
    });

    test('a remote edit later than a local edit wins', () async {
      await AppSettingsService.instance.saveDailyKcalGoal(1500); // now
      final remoteJson = remoteBudgetJson(
        kcal: 1800,
        t: '2999-01-01T09:00:00',
      );
      final fake = FakeGitHub(
        deviceDirs: const ['pc'],
        files: {'diet-guard-sync/devices/pc/budget.json': remoteJson},
      );
      await runSync(fake.buildClient());
      expect(AppSettingsService.dailyKcalGoal, 1800);
    });

    test('a malformed remote budget is skipped, not a crash', () async {
      await AppSettingsService.instance.saveDailyKcalGoal(2000);
      final fake = FakeGitHub(
        deviceDirs: const ['pc'],
        files: const {
          'diet-guard-sync/devices/pc/budget.json': '{not valid json',
        },
      );
      await runSync(fake.buildClient());
      expect(AppSettingsService.dailyKcalGoal, 2000);
    });

    test(
      'a fresh install with no budget ever set contributes nothing',
      () async {
        final fake = FakeGitHub();
        await runSync(fake.buildClient());

        final pushed =
            fake.putsByPath['diet-guard-sync/devices/phone/budget.json']!;
        final pushedText = utf8.decode(
          base64.decode(pushed['content'] as String),
        );
        expect(jsonDecode(pushedText), isEmpty);
        expect(AppSettingsService.dailyKcalGoal, 2200);
      },
    );
  });
}
