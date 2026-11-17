// Guard: the log-meal, history, calendar and settings screens paint no
// words; only the logged food name (content), numbers and unit symbols.
//
// The date/time pickers are not opened here: pickers/no_words_pickers_test.dart
// opens each one through its call site.

import 'dart:io';

import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/screens/calendar_screen.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/screens/log_meal_future_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/screens/settings_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_secure_storage.dart';
import 'label_finders.dart';
import 'no_words_support.dart';
import 'screens/log_meal_test_support.dart' show pinLogMealClock;

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

  testWidgets('a future date with no slot paints a cue, not a sentence', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await show(tester, const LogMealScreen());
      final state = tester.state<State<LogMealScreen>>(
        find.byType(LogMealScreen),
      );
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      await (state as LogMealFutureMixin<LogMealScreen>).selectLogDate(
        tomorrow,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, _food);
      await tester.pump();
      final log = controlByLabel('Log meal');
      await tester.ensureVisible(log);
      await tester.tap(log);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 1));
      expect(cueLabelled('Pick a slot for that date first.'), findsOneWidget);
      expectNoWords(tester, content: {_food}, minStrings: 3, where: 'cue');
    });
  });

  testWidgets('due mode and a logged row paint no words', (tester) async {
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await show(tester, const LogMealScreen());
      await tester.enterText(find.byType(TextField).first, _food);
      await tester.pump();
      await tester.tap(controlByLabel('Log meal'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 1));
      expectNoWords(tester, content: {_food}, minStrings: 5, where: 'due');
    });
  });
}
