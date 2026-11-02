import 'dart:io';

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_feedback.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  final haptics = <String>[];
  var cues = 0;

  setUp(() async {
    haptics.clear();
    cues = 0;
    LogFeedback.playConfirmCue = () async => cues++;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
    dir = await Directory.systemTemp.createTemp('diet_guard_haptic_');
    LogStorageService.resetForTesting(store: FileDocumentStore(dir));
    FoodBankService.resetForTesting(store: FileDocumentStore(dir));
    AppSettingsService.resetForTesting(store: FileDocumentStore(dir));
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(dir));
    await MealScheduleService.initForTesting(FileDocumentStore(dir));
  });

  tearDown(() async {
    LogFeedback.playConfirmCue = () async {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    MealScheduleService.resetForTesting();
    await dir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('logging a meal buzzes once, on the tap', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(0), 'toast');
      await settle(tester);
      await tester.tap(find.byTooltip('Log meal'));
      // One frame, no I/O wait: the haptic must not wait for the write.
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      expect(cues, 1);
      await settle(tester);
      expect(haptics, hasLength(1));
      expect(cues, 1);
    });
  });

  testWidgets('sound off silences the cue but keeps the haptic', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await AppSettingsService.instance.setSoundOnLog(on: false);
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(0), 'toast');
      await settle(tester);
      await tester.tap(find.byTooltip('Log meal'));
      await settle(tester);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      expect(cues, 0);
    });
  });

  testWidgets('a rejected log (empty description) does not buzz', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);
      await tester.tap(find.byTooltip('Log meal'));
      await settle(tester);
      expect(find.text('Type what you ate first.'), findsOneWidget);
      expect(haptics, isEmpty);
      expect(cues, 0);
    });
  });
}
