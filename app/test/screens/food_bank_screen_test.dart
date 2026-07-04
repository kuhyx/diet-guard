import 'dart:io';

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_fb_screen_');
    FoodBankService.resetForTesting(testDir: tempDir);
    LogStorageService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    FoodBankService.resetForTesting();
    LogStorageService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  // ---------------------------------------------------------------------------
  // applyFbFilter — pure function tests
  // ---------------------------------------------------------------------------

  group('applyFbFilter', () {
    final records = [
      const FoodBankRecord(
        desc: 'Apple',
        kcal: 80,
        proteinG: 0.5,
        carbsG: 20,
        fatG: 0.3,
        grams: 100,
        count: 5,
      ),
      const FoodBankRecord(
        desc: 'Banana',
        kcal: 90,
        proteinG: 1,
        carbsG: 22,
        fatG: 0.4,
        grams: 100,
        count: 10,
      ),
      const FoodBankRecord(
        desc: 'Chicken breast',
        kcal: 165,
        proteinG: 31,
        carbsG: 0,
        fatG: 3.6,
        grams: 100,
        count: 2,
      ),
    ];

    test('no filter returns entries sorted by count descending', () {
      final result = applyFbFilter(
        records,
        FbFilter(),
        FbSortField.count,
        ascending: false,
      );
      expect(result.map((r) => r.desc), ['Banana', 'Apple', 'Chicken breast']);
    });

    test('nameQuery filters by case-insensitive substring', () {
      final result = applyFbFilter(
        records,
        FbFilter(nameQuery: 'an'),
        FbSortField.name,
        ascending: true,
      );
      expect(result.map((r) => r.desc), [
        'Banana',
      ]); // only 'Banana' contains 'an'
    });

    test('minKcal and maxKcal filter by kcal', () {
      final result = applyFbFilter(
        records,
        FbFilter(minKcal: 85, maxKcal: 100),
        FbSortField.kcal,
        ascending: true,
      );
      expect(result.map((r) => r.desc), ['Banana']);
    });

    test('minProtein filters by protein', () {
      final result = applyFbFilter(
        records,
        FbFilter(minProtein: 10),
        FbSortField.count,
        ascending: false,
      );
      expect(result.map((r) => r.desc), ['Chicken breast']);
    });

    test('maxCarbs filters by carbs', () {
      final result = applyFbFilter(
        records,
        FbFilter(maxCarbs: 5),
        FbSortField.count,
        ascending: false,
      );
      expect(result.map((r) => r.desc), ['Chicken breast']);
    });

    test('minFat and maxFat filter by fat', () {
      final result = applyFbFilter(
        records,
        FbFilter(minFat: 0.35, maxFat: 1),
        FbSortField.count,
        ascending: false,
      );
      expect(result.map((r) => r.desc), ['Banana']);
    });

    test('maxProtein filters by protein', () {
      final result = applyFbFilter(
        records,
        FbFilter(maxProtein: 5),
        FbSortField.count,
        ascending: false,
      );
      // Banana (1 g) and Apple (0.5 g) have protein ≤ 5 g; sorted count desc.
      expect(result.map((r) => r.desc), ['Banana', 'Apple']);
    });

    test('minCarbs filters by carbs', () {
      final result = applyFbFilter(
        records,
        FbFilter(minCarbs: 10),
        FbSortField.count,
        ascending: false,
      );
      // Banana (22 g) and Apple (20 g) have carbs ≥ 10 g; sorted count desc.
      expect(result.map((r) => r.desc), ['Banana', 'Apple']);
    });

    test('sort ascending by name', () {
      final result = applyFbFilter(
        records,
        FbFilter(),
        FbSortField.name,
        ascending: true,
      );
      expect(result.map((r) => r.desc), ['Apple', 'Banana', 'Chicken breast']);
    });

    test('sort descending by kcal', () {
      final result = applyFbFilter(
        records,
        FbFilter(),
        FbSortField.kcal,
        ascending: false,
      );
      expect(result.first.desc, 'Chicken breast');
    });

    test('sort ascending by protein', () {
      final result = applyFbFilter(
        records,
        FbFilter(),
        FbSortField.protein,
        ascending: true,
      );
      expect(result.first.desc, 'Apple');
    });

    test('sort by carbs ascending', () {
      final result = applyFbFilter(
        records,
        FbFilter(),
        FbSortField.carbs,
        ascending: true,
      );
      expect(result.first.desc, 'Chicken breast'); // 0g
    });

    test('sort by fat descending', () {
      final result = applyFbFilter(
        records,
        FbFilter(),
        FbSortField.fat,
        ascending: false,
      );
      expect(result.first.desc, 'Chicken breast'); // 3.6g
    });

    test('FbFilter.isActive is false when nothing is set', () {
      expect(FbFilter().isActive, isFalse);
    });

    test('FbFilter.isActive is true when nameQuery is set', () {
      expect(FbFilter(nameQuery: 'x').isActive, isTrue);
    });

    test('FbFilter.isActive is true when minKcal is set', () {
      expect(FbFilter(minKcal: 50).isActive, isTrue);
    });

    test('FbFilter.isActive is true when maxKcal is set', () {
      expect(FbFilter(maxKcal: 500).isActive, isTrue);
    });

    test('FbFilter.isActive is true when minProtein is set', () {
      expect(FbFilter(minProtein: 5).isActive, isTrue);
    });

    test('FbFilter.isActive is true when maxProtein is set', () {
      expect(FbFilter(maxProtein: 50).isActive, isTrue);
    });

    test('FbFilter.isActive is true when minCarbs is set', () {
      expect(FbFilter(minCarbs: 5).isActive, isTrue);
    });

    test('FbFilter.isActive is true when maxCarbs is set', () {
      expect(FbFilter(maxCarbs: 50).isActive, isTrue);
    });

    test('FbFilter.isActive is true when minFat is set', () {
      expect(FbFilter(minFat: 1).isActive, isTrue);
    });

    test('FbFilter.isActive is true when maxFat is set', () {
      expect(FbFilter(maxFat: 10).isActive, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Widget tests
  // ---------------------------------------------------------------------------

  testWidgets('shows empty-bank message when no entries exist', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      expect(find.textContaining('Food bank is empty'), findsOneWidget);
    });
  });

  testWidgets('lists entries from the merged bank', (tester) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Manual oat',
          kcal: 370,
          proteinG: 13,
          carbsG: 66,
          fatG: 7,
          grams: 100,
          count: 0,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      expect(find.text('Manual oat'), findsOneWidget);
    });
  });

  testWidgets('FAB opens add-entry dialog and saving adds to bank', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);

      expect(find.text('Add to food bank'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'Test food',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Kcal'),
        '200',
      );

      await tester.tap(find.text('Save to bank'));
      await settle(tester);

      // After saving, the screen reloads and shows the new entry.
      expect(find.text('Test food'), findsOneWidget);
    });
  });

  testWidgets('dialog cancel does not save anything', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);

      await tester.tap(find.text('Cancel'));
      await settle(tester);

      expect(find.textContaining('Food bank is empty'), findsOneWidget);
    });
  });

  testWidgets('dialog save with empty name does nothing', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);

      // Tap save without entering a name.
      await tester.tap(find.text('Save to bank'));
      await settle(tester);

      // Dialog stays open; no entry saved.
      expect(find.text('Add to food bank'), findsOneWidget);
    });
  });

  testWidgets('filter icon appears when entries exist', (tester) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Oat',
          kcal: 370,
          proteinG: 13,
          carbsG: 66,
          fatG: 7,
          grams: 100,
          count: 0,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      expect(
        find.widgetWithIcon(IconButton, Icons.filter_list),
        findsOneWidget,
      );
    });
  });

  testWidgets('filter sheet opens and Apply filters results', (tester) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Oat',
          kcal: 370,
          proteinG: 13,
          carbsG: 66,
          fatG: 7,
          grams: 100,
          count: 0,
        ),
      );
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Egg',
          kcal: 155,
          proteinG: 13,
          carbsG: 1,
          fatG: 11,
          grams: 100,
          count: 0,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsOneWidget);

      // Type in the only TextField in the sheet (the name search field).
      await tester.enterText(find.byType(TextField).first, 'Oat');
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      // Sheet is closed; only the matching entry is visible.
      expect(find.text('Filter & Sort'), findsNothing);
      expect(find.text('Oat'), findsOneWidget);
      expect(find.text('Egg'), findsNothing);
    });
  });

  testWidgets('filter sheet Clear all resets draft then Apply shows all', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'Walnut',
          kcal: 654,
          proteinG: 15,
          carbsG: 14,
          fatG: 65,
          grams: 100,
          count: 0,
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      await tester.tap(find.text('Clear all'));
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('Walnut'), findsOneWidget);
    });
  });

  testWidgets('record tile shows usage count for log-derived entries', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await FoodBankService.instance.rebuildAndPersist({
        '2026-06-22': [
          const FoodEntry(
            id: '1',
            time: '2026-06-22T08:00:00+02:00',
            desc: 'rice',
            grams: 100,
            kcal: 130,
            proteinG: 3,
            carbsG: 28,
            fatG: 0.3,
            source: 'manual',
          ),
          const FoodEntry(
            id: '2',
            time: '2026-06-22T12:00:00+02:00',
            desc: 'rice',
            grams: 100,
            kcal: 130,
            proteinG: 3,
            carbsG: 28,
            fatG: 0.3,
            source: 'manual',
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      // The rice entry was logged twice — the tile trailing shows ×2.
      expect(find.textContaining('×2'), findsOneWidget);
    });
  });

  testWidgets('filter sheet sort dropdown changes sort field', (tester) async {
    await tester.runAsync(() async {
      // Zero macros: no RangeSliders appear, sort section is immediately visible.
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'ZeroItem',
          kcal: 0,
          proteinG: 0,
          carbsG: 0,
          fatG: 0,
          grams: 100,
          count: 0,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsOneWidget);

      // With no sliders rendered, 'Sort by' and its dropdown are immediately
      // visible — open the sort-field dropdown (shows 'Usage count' by default).
      await tester.tap(find.text('Usage count'));
      await settle(tester);

      // Tap 'Name' in the dropdown overlay.
      await tester.tap(find.text('Name').last);
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsNothing);
      expect(find.text('ZeroItem'), findsOneWidget);
    });
  });

  testWidgets('filter sheet RangeSlider onChanged callbacks fire', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Non-zero macros: all four RangeSliders appear in the filter sheet.
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'SliderFood',
          kcal: 200,
          proteinG: 10,
          carbsG: 25,
          fatG: 8,
          grams: 100,
          count: 0,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      // Use getRect() + dragFrom() to bypass the _maybeViewOf ancestor-search
      // failure that tester.drag(finder, …) triggers inside modal overlays.

      // Kcal slider covers lines 468-471.
      await tester.dragFrom(
        tester.getRect(find.byType(RangeSlider).at(0)).center,
        const Offset(-30, 0),
      );
      await settle(tester);

      // Protein slider covers lines 491-495.
      await tester.dragFrom(
        tester.getRect(find.byType(RangeSlider).at(1)).center,
        const Offset(-30, 0),
      );
      await settle(tester);

      // Carbs slider covers lines 515-518.
      await tester.dragFrom(
        tester.getRect(find.byType(RangeSlider).at(2)).center,
        const Offset(-30, 0),
      );
      await settle(tester);

      // Fat slider covers lines 538-541.
      await tester.dragFrom(
        tester.getRect(find.byType(RangeSlider).at(3)).center,
        const Offset(-30, 0),
      );
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsNothing);
    });
  });

  testWidgets('filter sheet sort direction toggle fires onSortChanged', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Zero macros: no RangeSliders appear, sort section is immediately visible.
      await FoodBankService.instance.addManualEntry(
        const FoodBankRecord(
          desc: 'ZeroItem2',
          kcal: 0,
          proteinG: 0,
          carbsG: 0,
          fatG: 0,
          grams: 100,
          count: 0,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: FoodBankScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsOneWidget);

      // Default sort is count-descending; the direction icon is arrow_downward.
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('ZeroItem2'), findsOneWidget);
    });
  });
}
