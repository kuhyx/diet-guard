import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/log_meal_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_screen_');
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  final logMealButton = find.widgetWithText(ElevatedButton, 'Log meal');

  // The screen's button handlers and description-field listener trigger
  // real `dart:io` file I/O as fire-and-forget Futures that Flutter's frame
  // scheduler does not track -- pumpAndSettle() can return *before* that
  // I/O (and its eventual setState) actually finishes. Every interaction
  // that can reach a service call therefore runs inside a single
  // tester.runAsync() per test, with a short real delay before each
  // pumpAndSettle() to let the in-flight I/O actually complete first.
  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('logging a manually-typed meal persists it as source manual',
      (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.enterText(find.byType(TextField).at(0), 'toast');
      await settle(tester);
      await tester.enterText(find.byType(TextField).at(1), '150');
      await tester.enterText(find.byType(TextField).at(3), '5');
      await tester.enterText(find.byType(TextField).at(4), '20');
      await tester.enterText(find.byType(TextField).at(5), '3');
      await settle(tester);

      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Logged "toast".'), findsOneWidget);
      final entries = await LogStorageService.instance.todayEntries();
      expect(entries.single.source, 'manual');
      expect(entries.single.kcal, 150);
    });
  });

  testWidgets('refuses to log with an empty description', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
      await settle(tester);

      await tester.tap(logMealButton);
      await settle(tester);

      expect(find.text('Type what you ate first.'), findsOneWidget);
      expect(await LogStorageService.instance.todayEntries(), isEmpty);
    });
  });

  testWidgets(
    'per-grams and amount-eaten fields scale macros to the eaten portion',
    (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
        await settle(tester);

        await tester.enterText(find.byType(TextField).at(0), 'label food');
        await settle(tester);
        await tester.enterText(find.byType(TextField).at(1), '200');
        await tester.enterText(find.byType(TextField).at(2), '100');
        await tester.enterText(find.byType(TextField).at(3), '10');
        await tester.enterText(find.byType(TextField).at(4), '20');
        await tester.enterText(find.byType(TextField).at(5), '5');
        await tester.enterText(find.byType(TextField).at(6), '150');
        await settle(tester);

        await tester.tap(logMealButton);
        await settle(tester);

        final entry =
            (await LogStorageService.instance.todayEntries()).single;
        expect(entry.kcal, 300);
        expect(entry.proteinG, 15);
        expect(entry.carbsG, 30);
        expect(entry.fatG, 7.5);
        expect(entry.grams, 150);
      });
    },
  );

  testWidgets(
    'selecting a food-bank suggestion stamps source food bank, but '
    'editing a macro afterward reverts it to manual',
    (tester) async {
      await tester.runAsync(() async {
        const seed = FoodEntry(
          id: 'seed-1',
          time: '2026-06-01T08:00:00+02:00',
          desc: 'seeded food',
          grams: 100,
          kcal: 250,
          proteinG: 10,
          carbsG: 30,
          fatG: 8,
          source: 'manual',
        );
        await FoodBankService.instance.rebuildAndPersist({
          '2026-06-01': [seed],
        });

        await tester.pumpWidget(const MaterialApp(home: LogMealScreen()));
        await settle(tester);

        // The empty-query suggestion list shows the only banked food.
        await tester.tap(find.text('seeded food'));
        await settle(tester);
        await tester.tap(logMealButton);
        await settle(tester);

        final firstEntry =
            (await LogStorageService.instance.todayEntries()).single;
        expect(firstEntry.source, 'food bank');
        expect(firstEntry.kcal, 250);

        await tester.tap(find.text('seeded food'));
        await settle(tester);
        await tester.enterText(find.byType(TextField).at(1), '999');
        await settle(tester);
        await tester.tap(logMealButton);
        await settle(tester);

        final secondEntry =
            (await LogStorageService.instance.todayEntries()).last;
        expect(secondEntry.source, 'manual');
        expect(secondEntry.kcal, 999);
      });
    },
  );
}
