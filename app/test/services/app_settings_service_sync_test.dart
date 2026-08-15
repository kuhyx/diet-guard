import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'diet_guard_settings_test_',
    );
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
  });

  tearDown(() async {
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  group('applySyncedBudget', () {
    test(
      'persists the given value and updatedAt verbatim, not "now"',
      () async {
        AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
        BudgetHistoryService.resetForTesting(
          store: FileDocumentStore(tempDir),
        );
        final winningEdit = DateTime.utc(2020);

        await AppSettingsService.instance.applySyncedBudget(
          1700,
          updatedAt: winningEdit,
        );

        expect(AppSettingsService.dailyKcalGoal, 1700);
        expect(AppSettingsService.dailyKcalGoalUpdatedAt, winningEdit);

        final raw = await File(
          '${tempDir.path}/app_settings.json',
        ).readAsString();
        final data = jsonDecode(raw) as Map;
        expect(data['daily_kcal_goal'], 1700);
        expect(
          data['daily_kcal_goal_updated_at'],
          winningEdit.toIso8601String(),
        );
      },
    );

    test('a null updatedAt is accepted and persisted as null', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );
      await AppSettingsService.instance.applySyncedBudget(1700);
      expect(AppSettingsService.dailyKcalGoalUpdatedAt, isNull);
    });
  });
  group('initForTesting (_load paths)', () {
    test('loads daily_kcal_goal from an existing file', () async {
      await File(
        '${tempDir.path}/app_settings.json',
      ).writeAsString(jsonEncode({'daily_kcal_goal': 1600}));

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );

      expect(AppSettingsService.dailyKcalGoal, 1600);
    });

    test('keeps default 2200 when file does not exist', () async {
      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );

      expect(AppSettingsService.dailyKcalGoal, 2200);
    });

    test('keeps default 2200 on unparsable JSON', () async {
      await File(
        '${tempDir.path}/app_settings.json',
      ).writeAsString('not json at all');

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );

      expect(AppSettingsService.dailyKcalGoal, 2200);
    });

    test('keeps default 2200 when JSON root is not a Map', () async {
      await File(
        '${tempDir.path}/app_settings.json',
      ).writeAsString(jsonEncode([1, 2, 3]));

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );

      expect(AppSettingsService.dailyKcalGoal, 2200);
    });

    test('keeps default 2200 when daily_kcal_goal is not an int', () async {
      await File(
        '${tempDir.path}/app_settings.json',
      ).writeAsString(jsonEncode({'daily_kcal_goal': 'two thousand'}));

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );

      expect(AppSettingsService.dailyKcalGoal, 2200);
    });

    test('loads daily_kcal_goal_updated_at from an existing file', () async {
      await File('${tempDir.path}/app_settings.json').writeAsString(
        jsonEncode({
          'daily_kcal_goal': 1600,
          'daily_kcal_goal_updated_at': '2026-01-01T00:00:00.000Z',
        }),
      );

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );

      expect(
        AppSettingsService.dailyKcalGoalUpdatedAt,
        DateTime.parse('2026-01-01T00:00:00.000Z'),
      );
    });

    test(
      'dailyKcalGoalUpdatedAt stays null when file has no such key',
      () async {
        await File(
          '${tempDir.path}/app_settings.json',
        ).writeAsString(jsonEncode({'daily_kcal_goal': 1600}));

        await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
        BudgetHistoryService.resetForTesting(
          store: FileDocumentStore(tempDir),
        );

        expect(AppSettingsService.dailyKcalGoalUpdatedAt, isNull);
      },
    );

    test(
      'dailyKcalGoalUpdatedAt stays null when the field is not a string',
      () async {
        await File('${tempDir.path}/app_settings.json').writeAsString(
          jsonEncode({
            'daily_kcal_goal': 1600,
            'daily_kcal_goal_updated_at': 12345,
          }),
        );

        await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
        BudgetHistoryService.resetForTesting(
          store: FileDocumentStore(tempDir),
        );

        expect(AppSettingsService.dailyKcalGoalUpdatedAt, isNull);
      },
    );
  });
}
