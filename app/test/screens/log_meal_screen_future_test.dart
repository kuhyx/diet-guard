import 'dart:io';

import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers logging a meal against a future date/slot through [LogMealScreen]'s
/// "When" row -- its own file, split out the same way
/// `log_meal_screen_nav_test.dart` and `log_meal_screen_sync_test.dart` are.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_future_');
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

  final logMealButton = find.byTooltip('Log meal');

  // See log_meal_screen_test.dart's `settle` for why: fire-and-forget I/O
  // that pumpAndSettle() alone does not wait for.
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  DateTime tomorrow() {
    final today = DateTime.now();
    return DateTime(today.year, today.month, today.day + 1);
  }

  testWidgets(
    'logging for a future date/slot persists under that date, not today, '
    'and resets back to Today',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
        await settle(tester);

        await tester.tap(find.text('Log for later'));
        await settle(tester);
        // The date picker's initialDate is already tomorrow, so confirming
        // immediately picks it without touching a specific calendar cell.
        await tester.tap(find.text('OK'));
        await settle(tester);

        final tomorrowKey = localDateKey(tomorrow());
        expect(find.text(tomorrowKey), findsOneWidget);

        final firstSlot = daySlots(MealScheduleService.current).first;
        await tester.tap(find.text(slotLabel(firstSlot)));
        await settle(tester);

        await tester.enterText(find.byType(TextField).at(0), 'future meal');
        await settle(tester);
        await tester.enterText(find.byType(TextField).at(2), '150');
        await settle(tester);

        await tester.ensureVisible(logMealButton);
        await tester.tap(logMealButton);
        await settle(tester);

        expect(await LogStorageService.instance.todayEntries(), isEmpty);
        final log = await LogStorageService.instance.readLog();
        final future = log[tomorrowKey]!.single;
        expect(future.desc, 'future meal');
        expect(future.slot, firstSlot);
        expect(future.time.startsWith(tomorrowKey), isTrue);

        // Back to logging for today.
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('Log for later'), findsOneWidget);
      });
    },
  );

  testWidgets('refuses to log a future date with no slot picked', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(find.text('Log for later'));
      await settle(tester);
      await tester.tap(find.text('OK'));
      await settle(tester);

      await tester.enterText(find.byType(TextField).at(0), 'no slot meal');
      await settle(tester);

      await tester.ensureVisible(logMealButton);
      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Pick a slot for that date first.'), findsOneWidget);
      final log = await LogStorageService.instance.readLog();
      expect(log.values.expand((e) => e), isEmpty);
    });
  });

  testWidgets('the "x" button clears the future date back to today', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(find.text('Log for later'));
      await settle(tester);
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(find.text('Today'), findsNothing);

      await tester.tap(find.byTooltip('Back to today'));
      await settle(tester);

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Log for later'), findsOneWidget);
    });
  });
}
