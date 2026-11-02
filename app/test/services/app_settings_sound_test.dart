import 'dart:io';

import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('diet_guard_sound_');
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(dir));
  });

  tearDown(() async {
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    await dir.delete(recursive: true);
  });

  Future<AppSettingsService> reload() {
    AppSettingsService.resetForTesting();
    return AppSettingsService.initForTesting(FileDocumentStore(dir));
  }

  test('sound on log ships on, even uninitialised', () async {
    AppSettingsService.resetForTesting();
    expect(AppSettingsService.soundOnLog, isTrue);
    await reload();
    expect(AppSettingsService.soundOnLog, isTrue);
  });

  test('turning it off survives a restart', () async {
    final svc = await reload();
    await svc.setSoundOnLog(on: false);
    await reload();
    expect(AppSettingsService.soundOnLog, isFalse);
  });

  test('a kcal goal save keeps the sound setting', () async {
    final svc = await reload();
    await svc.setSoundOnLog(on: false);
    await svc.saveDailyKcalGoal(1900);
    await reload();
    expect(AppSettingsService.soundOnLog, isFalse);
    expect(AppSettingsService.dailyKcalGoal, 1900);
  });

  test('toggling sound does not restamp the synced budget', () async {
    final svc = await reload();
    await svc.applySyncedBudget(2000, updatedAt: DateTime.utc(2026));
    await svc.setSoundOnLog(on: false);
    await reload();
    expect(AppSettingsService.dailyKcalGoalUpdatedAt, DateTime.utc(2026));
  });

  test('a non-bool stored value falls back to on', () async {
    await FileDocumentStore(
      dir,
    ).write(AppSettingsService.documentName, '{"sound_on_log": "no"}');
    await reload();
    expect(AppSettingsService.soundOnLog, isTrue);
  });
}
