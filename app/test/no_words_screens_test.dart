// Guard: the log-meal, history, calendar and settings screens paint no
// words; only the logged food name (content), numbers and unit symbols.
//
// Date/time pickers are framework chrome and are not opened here: they are a
// follow-up task (custom icon pickers), listed in the rework report.

import 'dart:io';

import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/screens/calendar_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_secure_storage.dart';
import 'label_finders.dart';
import 'no_words_support.dart';

/// The one meal logged in setUp: user content, allowed.
const _food = 'porridge';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_no_words_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));
    await MealScheduleService.initForTesting(FileDocumentStore(tempDir));
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    MealScheduleService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> show(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: screen));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  Future<void> logOne() => LogStorageService.instance.logMeal(
    _food,
    const Nutrition(
      kcal: 350,
      proteinG: 12,
      carbsG: 50,
      fatG: 8,
      grams: 300,
      source: 'manual',
    ),
  );

  final screens = <String, Widget Function()>{
    'log meal': LogMealScreen.new,
    'history': HistoryScreen.new,
    'calendar': CalendarScreen.new,
    'settings': SettingsScreen.new,
  };
  for (final MapEntry(key: name, value: build) in screens.entries) {
    testWidgets('$name paints no words', (tester) async {
      await tester.runAsync(() async {
        await logOne();
        await show(tester, build());
        expectNoWords(tester, content: {_food}, minStrings: 3, where: name);
      });
    });
  }

  testWidgets('a rejected log paints a cue, not a sentence', (tester) async {
    await tester.runAsync(() async {
      await show(tester, const LogMealScreen());
      final log = controlByLabel('Log meal');
      await tester.ensureVisible(log);
      await tester.tap(log);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 1));
      expect(cueLabelled('Type what you ate first.'), findsOneWidget);
      expectNoWords(tester, minStrings: 3, where: 'rejected log');
    });
  });
}
