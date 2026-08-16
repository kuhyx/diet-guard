/// The log screen's slot row versus a meal-schedule change.
///
/// Split from `log_meal_screen_test.dart` for the repo's 250-line cap.
library;

import 'dart:io';

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/screens/log_meal_nav_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_sched_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));
    await MealScheduleService.initForTesting(FileDocumentStore(tempDir));
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    MealScheduleService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('the slot row follows a schedule change made in settings', (
    tester,
  ) async {
    // Found on the phone: the settings preview and the overdue reminder both
    // picked up a four -> five meal change while the row behind them kept
    // rendering the old four checkpoints until the app was restarted, because
    // onOpenSettings pushed without awaiting the pop.
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);
      expect(find.text('12:00'), findsOneWidget);

      await MealScheduleService.instance.recordChange(
        const MealSchedule(first: 8, last: 20, count: 5),
      );
      final state = tester.state<State<LogMealScreen>>(
        find.byType(LogMealScreen),
      );
      await (state as LogMealNavMixin<LogMealScreen>)
          .onScheduleMayHaveChanged();
      await settle(tester);

      expect(find.text('11:00'), findsOneWidget);
      expect(find.text('17:00'), findsOneWidget);
      expect(find.text('12:00'), findsNothing);
    });
  });
}
