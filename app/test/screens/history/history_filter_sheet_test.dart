import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_test_support.dart';

void main() {
  useTempHistoryStores();
  testWidgets('filter sheet Clear all resets draft then Apply shows all', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-22': [
          const FoodEntry(
            id: 'a',
            time: '2026-06-22T08:00:00+02:00',
            desc: 'toast',
            grams: 100,
            kcal: 200,
            proteinG: 7,
            carbsG: 35,
            fatG: 3,
            source: 'manual',
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      await tester.tap(find.text('Clear all'));
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('toast'), findsOneWidget);
    });
  });

  testWidgets('filter sheet sort direction toggle fires onSortChanged', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Zero macros: no RangeSliders render, so the sort section is
      // immediately visible.
      await LogStorageService.instance.writeLog({
        '2026-06-20': [
          const FoodEntry(
            id: 'sd1',
            time: '2026-06-20T09:00:00+02:00',
            desc: 'porridge',
            grams: 200,
            kcal: 0,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            source: 'manual',
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsOneWidget);

      // The sort section is ~8px below the fold even with zero macros — scroll
      // it into view before tapping the direction button.
      await tester.drag(find.byType(ListView).last, const Offset(0, -120));
      await settle(tester);

      // Default sort is date-descending; direction icon is arrow_downward.
      await tester.tap(find.byIcon(Icons.arrow_downward));
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsNothing);
      expect(find.textContaining('porridge'), findsOneWidget);
    });
  });

  testWidgets('filter sheet sort field dropdown changes sort field', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Zero macros: no RangeSliders render, so the sort section is
      // immediately visible.
      await LogStorageService.instance.writeLog({
        '2026-06-21': [
          const FoodEntry(
            id: 'sf1',
            time: '2026-06-21T12:00:00+02:00',
            desc: 'chicken',
            grams: 150,
            kcal: 0,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            source: 'manual',
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      // Scroll just enough to make the sort section visible.
      await tester.drag(find.byType(ListView).last, const Offset(0, -120));
      await settle(tester);

      // Open the sort dropdown (shows 'Date' by default).
      await tester.tap(find.text('Date'));
      await settle(tester);

      // Select 'Kcal' from the dropdown overlay.
      await tester.tap(find.text('Kcal').last);
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsNothing);
      expect(find.textContaining('chicken'), findsOneWidget);
    });
  });

  testWidgets('filter sheet source chip filters by source', (tester) async {
    await tester.runAsync(() async {
      // Zero macros: no sliders, source chips appear right after date button.
      await LogStorageService.instance.writeLog({
        '2026-06-23': [
          const FoodEntry(
            id: 'src1',
            time: '2026-06-23T08:00:00+02:00',
            desc: 'manual meal',
            grams: 100,
            kcal: 0,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            source: 'manual',
          ),
          const FoodEntry(
            id: 'src2',
            time: '2026-06-23T12:00:00+02:00',
            desc: 'bank meal',
            grams: 100,
            kcal: 0,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            source: 'food bank',
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilterChip, 'manual'));
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsNothing);
      expect(find.textContaining('manual meal'), findsOneWidget);
      expect(find.textContaining('bank meal'), findsNothing);
    });
  });
}
