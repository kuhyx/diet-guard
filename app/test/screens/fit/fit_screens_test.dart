// One-screen layout gate: every converted main screen fits a Pixel 6a with
// the status bar and nav bar insets and NO vertical scrolling.
//
// Overflow errors are ignored on purpose: flutter_test renders the Ahem font
// (every glyph 1em wide), which is far wider than the real phone font, so a
// text Row "overflows" here that fits on the device. Scroll extents and
// hit-testing are what this file asserts.

import 'dart:io';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/screens/body_screen.dart';
import 'package:diet_guard_app/screens/calendar_screen.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_record_tile.dart';
import 'package:diet_guard_app/widgets/today_progress_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../label_finders.dart';

import '../body_screen_support.dart';
import 'fit_support.dart';

Future<void> _pump(WidgetTester tester, Widget screen) async {
  usePixel6a(tester);
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (!details.toString().contains('overflowed')) previous!(details);
  };
  addTearDown(() => FlutterError.onError = previous);
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(home: screen));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  });
}

void main() {
  late Directory dir;
  late MemoryDocStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('diet_guard_fit_');
    store = MemoryDocStore();
    LogStorageService.resetForTesting(store: FileDocumentStore(dir));
    FoodBankService.resetForTesting(store: FileDocumentStore(dir));
    AppSettingsService.resetForTesting(store: FileDocumentStore(dir));
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(dir));
    await MealScheduleService.initForTesting(FileDocumentStore(dir));
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    MealScheduleService.resetForTesting();
    await dir.delete(recursive: true);
  });

  testWidgets('log meal screen fits', (tester) async {
    await _pump(tester, const LogMealScreen());
    expect(maxVerticalExtent(tester), 0);
  });

  testWidgets('log meal screen still fits once the progress card shows', (
    tester,
  ) async {
    await _pump(tester, const LogMealScreen());
    await tester.enterText(find.byType(TextField).first, 'Oats');
    await tester.runAsync(() async {
      await tester.tap(controlByLabel('Log meal'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TodayProgressCard), findsOneWidget);
    expect(maxVerticalExtent(tester), 0);
  });

  testWidgets('calendar screen fits', (tester) async {
    await _pump(tester, const CalendarScreen());
    expect(maxVerticalExtent(tester), 0);
  });

  testWidgets('food bank fits with 250 foods and pages through them', (
    tester,
  ) async {
    await tester.runAsync(
      () => FoodBankService.instance.writeBank({
        for (var i = 0; i < 250; i++)
          'food $i': FoodBankRecord(
            desc: 'Food ${i.toString().padLeft(3, '0')}',
            kcal: 100.0 + i,
            proteinG: 1,
            carbsG: 2,
            fatG: 3,
            grams: 100,
            count: 250.0 - i,
          ),
      }),
    );
    await _pump(tester, const FoodBankScreen());
    expect(maxVerticalExtent(tester), 0);
    final first = find.text('Food 000');
    expect(first, findsOneWidget);
    final box = tester.getRect(first);
    expect(box.bottom, lessThan(2400 / 2.625 - 24 - 72));
    // A tile is hit-testable, and long-press/tap opens its detail sheet.
    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(find.byType(RecordTile), findsOneWidget);
    await tester.tapAt(const Offset(200, 50)); // scrim closes the sheet
    await tester.pumpAndSettle();
    // Swiping to the next page reveals foods not on the first page.
    expect(find.text('Food 249'), findsNothing);
    await tester.fling(find.byType(PageView), const Offset(-600, 0), 2000);
    await tester.pumpAndSettle();
    expect(first, findsNothing);
  });

  testWidgets('body screen fits with a full profile', (tester) async {
    LogStorageService.resetForTesting(store: store);
    AppSettingsService.resetForTesting(store: store);
    await tester.runAsync(() => seedPerson(store));
    await _pump(tester, const BodyScreen());
    expect(maxVerticalExtent(tester), 0);
  });
}
