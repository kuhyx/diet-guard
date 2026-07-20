import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'diet_guard_settings_test_',
    );
    AppSettingsService.resetForTesting();
  });

  tearDown(() async {
    AppSettingsService.resetForTesting();
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
      expect(AppSettingsService.instance, isNotNull);
    });

    test('without testDir nulls the singleton', () {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      AppSettingsService.resetForTesting();
      // instance getter throws when null — verify via dailyKcalGoal fallback.
      expect(AppSettingsService.dailyKcalGoal, 2200);
    });
  });

  group('init early-return', () {
    test('returns existing instance without re-initialising', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      final first = AppSettingsService.instance;
      // init() sees _instance != null and returns early (no platform channel).
      final second = await AppSettingsService.init();
      expect(identical(first, second), isTrue);
    });
  });

  group('saveDailyKcalGoal', () {
    test('updates in-memory value and persists to file', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      await AppSettingsService.instance.saveDailyKcalGoal(1800);

      expect(AppSettingsService.dailyKcalGoal, 1800);

      final raw = await File(
        '${tempDir.path}/app_settings.json',
      ).readAsString();
      final data = jsonDecode(raw) as Map;
      expect(data['daily_kcal_goal'], 1800);
    });

    test('stamps a fresh dailyKcalGoalUpdatedAt', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
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

      expect(AppSettingsService.dailyKcalGoal, 1600);
    });

    test('keeps default 2200 when file does not exist', () async {
      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

      expect(AppSettingsService.dailyKcalGoal, 2200);
    });

    test('keeps default 2200 on unparsable JSON', () async {
      await File(
        '${tempDir.path}/app_settings.json',
      ).writeAsString('not json at all');

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

      expect(AppSettingsService.dailyKcalGoal, 2200);
    });

    test('keeps default 2200 when JSON root is not a Map', () async {
      await File(
        '${tempDir.path}/app_settings.json',
      ).writeAsString(jsonEncode([1, 2, 3]));

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

      expect(AppSettingsService.dailyKcalGoal, 2200);
    });

    test('keeps default 2200 when daily_kcal_goal is not an int', () async {
      await File(
        '${tempDir.path}/app_settings.json',
      ).writeAsString(jsonEncode({'daily_kcal_goal': 'two thousand'}));

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

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

        expect(AppSettingsService.dailyKcalGoalUpdatedAt, isNull);
      },
    );

    test('loads reward_label and reward_url from an existing file', () async {
      await File('${tempDir.path}/app_settings.json').writeAsString(
        jsonEncode({
          'daily_kcal_goal': 1600,
          'reward_label': 'Podcast',
          'reward_url': 'https://example.com/podcast',
        }),
      );

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

      expect(AppSettingsService.rewardLabel, 'Podcast');
      expect(AppSettingsService.rewardUrl, 'https://example.com/podcast');
    });

    test('reward fields stay null when the file has no such keys', () async {
      await File(
        '${tempDir.path}/app_settings.json',
      ).writeAsString(jsonEncode({'daily_kcal_goal': 1600}));

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

      expect(AppSettingsService.rewardLabel, isNull);
      expect(AppSettingsService.rewardUrl, isNull);
    });

    test('reward fields stay null when not strings', () async {
      await File('${tempDir.path}/app_settings.json').writeAsString(
        jsonEncode({
          'daily_kcal_goal': 1600,
          'reward_label': 123,
          'reward_url': false,
        }),
      );

      await AppSettingsService.initForTesting(FileDocumentStore(tempDir));

      expect(AppSettingsService.rewardLabel, isNull);
      expect(AppSettingsService.rewardUrl, isNull);
    });
  });

  group('rewardLabel / rewardUrl static getters', () {
    test('default to null when singleton is uninitialised', () {
      expect(AppSettingsService.rewardLabel, isNull);
      expect(AppSettingsService.rewardUrl, isNull);
    });
  });

  group('saveReward', () {
    test('persists label and url, readable back via static getters', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      await AppSettingsService.instance.saveReward(
        label: 'Podcast',
        url: 'https://example.com/podcast',
      );

      expect(AppSettingsService.rewardLabel, 'Podcast');
      expect(AppSettingsService.rewardUrl, 'https://example.com/podcast');

      final raw = await File(
        '${tempDir.path}/app_settings.json',
      ).readAsString();
      final data = jsonDecode(raw) as Map;
      expect(data['reward_label'], 'Podcast');
      expect(data['reward_url'], 'https://example.com/podcast');
    });

    test('clears fields back to null when saved as null', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      await AppSettingsService.instance.saveReward(
        label: 'Podcast',
        url: 'https://example.com/podcast',
      );
      await AppSettingsService.instance.saveReward(label: null, url: null);

      expect(AppSettingsService.rewardLabel, isNull);
      expect(AppSettingsService.rewardUrl, isNull);
    });

    test('does not disturb the existing kcal goal fields', () async {
      AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
      await AppSettingsService.instance.saveDailyKcalGoal(1800);
      await AppSettingsService.instance.saveReward(
        label: 'Podcast',
        url: 'https://example.com/podcast',
      );

      expect(AppSettingsService.dailyKcalGoal, 1800);

      final raw = await File(
        '${tempDir.path}/app_settings.json',
      ).readAsString();
      final data = jsonDecode(raw) as Map;
      expect(data['daily_kcal_goal'], 1800);
    });
  });
}
