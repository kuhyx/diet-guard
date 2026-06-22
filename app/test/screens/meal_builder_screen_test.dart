import 'dart:io';

import 'package:diet_guard_app/screens/meal_builder_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_builder_');
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  final addItemButton = find.widgetWithText(ElevatedButton, 'Add item');
  final logMealButton = find.widgetWithText(ElevatedButton, 'Log meal');

  // See log_meal_screen_test.dart: "Log meal" triggers real dart:io File
  // writes as an unawaited Future Flutter's scheduler doesn't track, so a
  // short real delay before settling is needed in addition to runAsync().
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('refuses to log a meal with no items added', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: MealBuilderScreen()));
      await settle(tester);

      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Add at least one item first.'), findsOneWidget);
    });
  });

  testWidgets(
    'adds an item with per/ate scaling applied, then logs the composite '
    'meal with full per-component macros',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          const MaterialApp(home: MealBuilderScreen()),
        );
        await settle(tester);

        // Field order: [0] meal name, [1] item name, [2] kcal,
        // [3] per (g), [4] protein, [5] carbs, [6] fat, [7] ate (g).
        await tester.enterText(find.byType(TextField).at(1), 'rice');
        await tester.enterText(find.byType(TextField).at(2), '200');
        await tester.enterText(find.byType(TextField).at(3), '100');
        await tester.enterText(find.byType(TextField).at(4), '4');
        await tester.enterText(find.byType(TextField).at(5), '44');
        await tester.enterText(find.byType(TextField).at(6), '1');
        await tester.enterText(find.byType(TextField).at(7), '150');
        await settle(tester);
        await tester.tap(addItemButton);
        await settle(tester);

        expect(find.textContaining('So far (1)'), findsOneWidget);
        expect(find.textContaining('300 kcal'), findsOneWidget);

        await tester.enterText(find.byType(TextField).at(1), 'chicken');
        await tester.enterText(find.byType(TextField).at(2), '165');
        await tester.enterText(find.byType(TextField).at(4), '31');
        await tester.enterText(find.byType(TextField).at(5), '0');
        await tester.enterText(find.byType(TextField).at(6), '4');
        await settle(tester);
        await tester.tap(addItemButton);
        await settle(tester);

        await tester.tap(logMealButton);
        await settle(tester);

        final entry =
            (await LogStorageService.instance.todayEntries()).single;
        expect(entry.source, 'meal');
        expect(entry.kcal, 465); // 300 (scaled rice) + 165 (chicken)
        expect(entry.components, hasLength(2));
        final rice = entry.components!.firstWhere((c) => c.name == 'rice');
        expect(rice.kcal, 300);
        expect(rice.proteinG, 6);
        expect(rice.carbsG, 66);
        expect(rice.fatG, 1.5);
        expect(rice.grams, 150);
      });
    },
  );
}
