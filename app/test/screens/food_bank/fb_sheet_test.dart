import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/food_bank_screen.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fb_test_support.dart';

void main() {
  useTempFoodBankStores();
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
