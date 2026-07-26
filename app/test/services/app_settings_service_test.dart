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

  group('dailyKcalGoal static getter', () {
    test('returns 2200 when singleton is uninitialised', () {
      // Singleton is null after resetForTesting() — exercises the ?? 2200 branch.
      expect(AppSettingsService.dailyKcalGoal, 2200);
    });
  });

  group('resetForTesting', () {
    test('with testDir creates a working instance', () {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );
      expect(AppSettingsService.instance, isNotNull);
    });

    test('without testDir nulls the singleton', () {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );
      AppSettingsService.resetForTesting();
      BudgetHistoryService.resetForTesting();
      // instance getter throws when null — verify via dailyKcalGoal fallback.
      expect(AppSettingsService.dailyKcalGoal, 2200);
    });
  });

  group('init early-return', () {
    test('returns existing instance without re-initialising', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );
      final first = AppSettingsService.instance;
      // init() sees _instance != null and returns early (no platform channel).
      final second = await AppSettingsService.init();
      expect(identical(first, second), isTrue);
    });
  });

  group('saveDailyKcalGoal', () {
    test('updates in-memory value and persists to file', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );
      await AppSettingsService.instance.saveDailyKcalGoal(1800);

      expect(AppSettingsService.dailyKcalGoal, 1800);

      final raw = await File(
        '${tempDir.path}/app_settings.json',
      ).readAsString();
      final data = jsonDecode(raw) as Map;
      expect(data['daily_kcal_goal'], 1800);
    });

    test('grandfathers the previous value to every past day', () async {
      // The load-bearing ordering test, on the real upgrade path: a device
      // that already had a goal (with an updatedAt, i.e. genuinely set)
      // gains a history the first time it loads, and a later edit must not
      // drag past days along with it. Asserts a PAST day -- a today-only
      // assertion passes even when the seed happens after the upsert.
      await File('${tempDir.path}/app_settings.json').writeAsString(
        jsonEncode({
          'daily_kcal_goal': 2200,
          'daily_kcal_goal_updated_at': '2026-07-13T21:15:09.000',
        }),
      );
      BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));
      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

      await AppSettingsService.instance.saveDailyKcalGoal(2000);

      expect(BudgetHistoryService.schedule.forDay('2020-01-01'), 2200);
      expect(BudgetHistoryService.schedule.current, 2000);
      expect(AppSettingsService.dailyKcalGoal, 2000);
    });

    test('loading an already-set goal seeds the history on its own', () async {
      // Seeding must not depend on the user making an edit: a device that
      // merely *synced* a goal still has to classify its history against
      // that goal, matching _budget.current_schedule's seed-on-read.
      await File('${tempDir.path}/app_settings.json').writeAsString(
        jsonEncode({
          'daily_kcal_goal': 1800,
          'daily_kcal_goal_updated_at': '2026-07-13T21:15:09.000',
        }),
      );
      BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

      expect(BudgetHistoryService.schedule.forDay('2020-01-01'), 1800);
    });

    test('a never-set goal seeds no phantom history', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));

      await AppSettingsService.instance.saveDailyKcalGoal(2000);

      // Nothing to grandfather, so the only entry is today's; past days fall
      // back to the current goal, exactly as _budget.current_schedule does.
      expect(BudgetHistoryService.schedule.entries, hasLength(1));
      expect(BudgetHistoryService.schedule.forDay('2020-01-01'), 2000);
    });

    test('a merge write-back records no history change', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));

      await AppSettingsService.instance.applySyncedBudget(
        1700,
        updatedAt: DateTime(2026, 7, 26),
      );

      // The sync layer applies merged history entries itself; a write-back
      // must not manufacture a local edit on top of them.
      expect(BudgetHistoryService.schedule.entries, isEmpty);
    });

    test('stamps a fresh dailyKcalGoalUpdatedAt', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      BudgetHistoryService.resetForTesting(
        store: FileDocumentStore(tempDir),
      );
      final before = DateTime.now();
      await AppSettingsService.instance.saveDailyKcalGoal(1800);
      final after = DateTime.now();

      final updatedAt = AppSettingsService.dailyKcalGoalUpdatedAt;
      expect(updatedAt, isNotNull);
      expect(updatedAt!.isBefore(before), isFalse);
      expect(updatedAt.isAfter(after), isFalse);
    });
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
