import 'dart:io';

import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/widgets/log_sound_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_secure_storage.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('diet_guard_sound_tile_');
    LogStorageService.resetForTesting(store: FileDocumentStore(dir));
    FoodBankService.resetForTesting(store: FileDocumentStore(dir));
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(dir));
    await AppSettingsService.initForTesting(FileDocumentStore(dir));
    await MealScheduleService.initForTesting(FileDocumentStore(dir));
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    MealScheduleService.resetForTesting();
    await dir.delete(recursive: true);
  });

  testWidgets('the switch reflects and persists the setting', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LogSoundTile())),
      );
      final tile = find.byType(SwitchListTile);
      expect(find.bySemanticsLabel('Sound on log'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);

      await tester.tap(tile);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);

      AppSettingsService.resetForTesting();
      await AppSettingsService.initForTesting(FileDocumentStore(dir));
      expect(AppSettingsService.soundOnLog, isFalse);
    });
  });

  testWidgets('settings screen carries the toggle', (tester) async {
    await tester.runAsync(() async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.byType(LogSoundTile), findsOneWidget);
    });
  });
}
