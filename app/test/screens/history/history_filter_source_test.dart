import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_test_support.dart';

void main() {
  useTempHistoryStores();
  testWidgets('filter sheet source All chip fires onSelected callback', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-25': [
          const FoodEntry(
            id: 'sa1',
            time: '2026-06-25T08:00:00+02:00',
            desc: 'all source entry',
            grams: 100,
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

      // Tap 'manual' to set a source filter, then 'All' to reset it.
      // Tapping 'All' when source is not null covers lines 798-800.
      await tester.tap(find.widgetWithText(FilterChip, 'manual'));
      await settle(tester);

      await tester.tap(find.widgetWithText(FilterChip, 'All'));
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsNothing);
      expect(find.textContaining('all source entry'), findsOneWidget);
    });
  });

  testWidgets('filter sheet RangeSlider onChanged callbacks fire', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Non-zero macros: all four RangeSliders appear in the filter sheet.
      await LogStorageService.instance.writeLog({
        '2026-06-26': [
          const FoodEntry(
            id: 'rs1',
            time: '2026-06-26T08:00:00+02:00',
            desc: 'slider test entry',
            grams: 100,
            kcal: 300,
            proteinG: 20,
            carbsG: 40,
            fatG: 10,
            source: 'manual',
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.filter_list));
      await settle(tester);

      // tester.drag(finder, offset) fails for RangeSliders inside a modal
      // overlay because its internal _maybeViewOf ancestor search cannot find
      // a View ancestor through the overlay's render subtree. Use
      // getRect()+dragFrom() instead (resolves via renderObjectOf, no
      // _maybeViewOf call).
      //
      // The filter sheet uses SingleChildScrollView+Column, so all four
      // sliders are always in the widget tree. ensureVisible() scrolls each
      // one into the viewport before getRect() is called.

      // Kcal slider.
      await tester.ensureVisible(find.byKey(const Key('kcal-range-slider')));
      await settle(tester);
      await tester.dragFrom(
        tester.getRect(find.byKey(const Key('kcal-range-slider'))).center,
        const Offset(-30, 0),
      );
      await settle(tester);

      // Protein slider.
      await tester.ensureVisible(
        find.byKey(const Key('protein-range-slider')),
      );
      await settle(tester);
      await tester.dragFrom(
        tester.getRect(find.byKey(const Key('protein-range-slider'))).center,
        const Offset(-30, 0),
      );
      await settle(tester);

      // Carbs slider.
      await tester.ensureVisible(find.byKey(const Key('carbs-range-slider')));
      await settle(tester);
      await tester.dragFrom(
        tester.getRect(find.byKey(const Key('carbs-range-slider'))).center,
        const Offset(-30, 0),
      );
      await settle(tester);

      // Fat slider.
      await tester.ensureVisible(find.byKey(const Key('fat-range-slider')));
      await settle(tester);
      await tester.dragFrom(
        tester.getRect(find.byKey(const Key('fat-range-slider'))).center,
        const Offset(-30, 0),
      );
      await settle(tester);

      await tester.tap(find.text('Apply'));
      await settle(tester);

      expect(find.text('Filter & Sort'), findsNothing);
    });
  });

  testWidgets(
    'date range picker selection shows _dateRangeLabel and Clear button '
    '(lines 232-234, 639-642)',
    (tester) async {
      await tester.runAsync(() async {
        await LogStorageService.instance.writeLog({
          '2026-06-26': [
            const FoodEntry(
              id: 'dr1',
              time: '2026-06-26T08:00:00+02:00',
              desc: 'range test',
              grams: 100,
              kcal: 200,
              proteinG: 10,
              carbsG: 20,
              fatG: 5,
              source: 'manual',
            ),
          ],
        });

        await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
        await settle(tester);

        await tester.tap(find.byIcon(Icons.filter_list));
        await settle(tester);

        // Open date range picker.
        await tester.tap(find.widgetWithText(OutlinedButton, 'Any date'));
        await settle(tester);

        // The picker opens on the current month (no `currentDate` override
        // and a null `initialDateRange`) and its `lastDate` is capped at
        // tomorrow, so days "10"+ aren't always selectable this early in a
        // month. Days "1" and "2" of the displayed month are always within
        // [firstDate, lastDate] regardless of which day it is when the test
        // runs.
        final now = DateTime.now();
        final expectedStart = DateTime(now.year, now.month);
        await tester.tap(find.text('1'));
        await settle(tester);
        await tester.tap(find.text('2'));
        await settle(tester);
        await tester.tap(find.text('Save'));
        await settle(tester);

        // After a successful selection the filter button label shows the
        // formatted range via _dateRangeLabel (lines 232-234). Use a date-
        // specific prefix so the kcal slider's "0 – N kcal" label is excluded.
        expect(
          find.textContaining(expectedStart.toString().substring(0, 10)),
          findsOneWidget,
        );

        // "Clear date range" is now visible — tap it to exercise lines 639-642.
        await tester.tap(find.text('Clear date range'));
        await settle(tester);
        expect(find.text('Any date'), findsOneWidget);
      });
    },
  );
}
