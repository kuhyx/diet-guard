/// The log screen's due slots versus a meal-schedule change.
///
/// Split from `log_meal_screen_test.dart` for the repo's 250-line cap.
library;

import 'dart:io';

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/screens/log_meal_due_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_nav_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'log_meal_test_support.dart' show pinLogMealClock;

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

  testWidgets('the due slots follow a schedule change made in settings', (
    tester,
  ) async {
    // Found on the phone: the settings preview and the overdue reminder both
    // picked up a schedule change while the screen behind them kept the old
    // checkpoints until the app was restarted, because onOpenSettings pushed
    // without awaiting the pop.
    pinLogMealClock(13);
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);
      final state = tester.state<State<LogMealScreen>>(
        find.byType(LogMealScreen),
      );
      final due = state as LogMealDueMixin<LogMealScreen>;
      expect(due.dueSlots, [480, 720]);

      await MealScheduleService.instance.recordChange(
        const MealSchedule(firstMinute: 9 * 60, lastMinute: 21 * 60, count: 4),
      );
      await (state as LogMealNavMixin<LogMealScreen>)
          .onScheduleMayHaveChanged();
      await settle(tester);

      expect(due.dueSlots, [540, 780]);
      expect(due.targetSlot, 540);
    });
  });
}
