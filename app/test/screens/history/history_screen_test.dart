import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/history_screen.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_test_support.dart';

void main() {
  useTempHistoryStores();
  testWidgets('a day header shows the budget that applied on that day', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // 2200 until 2026-06-15, 2000 from then on.
      await BudgetHistoryService.instance.applyMerged(const [
        BudgetEntry(
          effectiveFrom: kEpochDay,
          kcal: 2200,
          editedAt: '2026-01-01T00:00:00.000Z',
        ),
        BudgetEntry(
          effectiveFrom: '2026-06-15',
          kcal: 2000,
          editedAt: '2026-06-15T00:00:00.000Z',
        ),
      ]);
      await LogStorageService.instance.writeLog({
        '2026-06-01': [
          const FoodEntry(
            id: 'before',
            time: '2026-06-01T08:00:00+02:00',
            desc: 'before the cut',
            grams: 100,
            kcal: 2100,
            proteinG: 5,
            carbsG: 10,
            fatG: 2,
            source: 'manual',
          ),
        ],
        '2026-06-20': [
          const FoodEntry(
            id: 'after',
            time: '2026-06-20T08:00:00+02:00',
            desc: 'after the cut',
            grams: 100,
            kcal: 2100,
            proteinG: 5,
            carbsG: 10,
            fatG: 2,
            source: 'manual',
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      // Same 2100 kcal on both days, judged against different budgets --
      // lowering the budget must not repaint the earlier day.
      expect(find.text('2100 / 2200 kcal'), findsOneWidget);
      expect(find.text('2100 / 2000 kcal'), findsOneWidget);
    });
  });

  testWidgets('shows a message when nothing has been logged', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      expect(find.text('Nothing logged yet.'), findsOneWidget);
    });
  });

  testWidgets('lists logged entries newest first, excluding tombstones', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await LogStorageService.instance.writeLog({
        '2026-06-01': [
          const FoodEntry(
            id: 'old',
            time: '2026-06-01T08:00:00+02:00',
            desc: 'old breakfast',
            grams: 100,
            kcal: 100,
            proteinG: 5,
            carbsG: 10,
            fatG: 2,
            source: 'manual',
          ),
        ],
        '2026-06-22': [
          const FoodEntry(
            id: 'new',
            time: '2026-06-22T20:00:00+02:00',
            desc: 'new dinner',
            grams: 100,
            kcal: 200,
            proteinG: 10,
            carbsG: 20,
            fatG: 4,
            source: 'manual',
          ),
          const FoodEntry(
            id: 'gone',
            time: '2026-06-22T12:00:00+02:00',
            desc: 'undone lunch',
            grams: 100,
            kcal: 300,
            proteinG: 1,
            carbsG: 1,
            fatG: 1,
            source: 'manual',
            deleted: true,
          ),
        ],
      });

      await tester.pumpWidget(const MaterialApp(home: HistoryScreen()));
      await settle(tester);

      expect(find.text('new dinner'), findsOneWidget);
      expect(find.text('old breakfast'), findsOneWidget);
      expect(find.text('undone lunch'), findsNothing);

      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect((tiles[0].title! as Text).data, 'new dinner');
      expect((tiles[1].title! as Text).data, 'old breakfast');
    });
  });

  testWidgets(
    'initialDateRange pre-filters to just that day, matching a Calendar '
    'screen day tap',
    (tester) async {
      await tester.runAsync(() async {
        await LogStorageService.instance.writeLog({
          '2026-06-01': [
            const FoodEntry(
              id: 'other-day',
              time: '2026-06-01T08:00:00+02:00',
              desc: 'other day breakfast',
              grams: 100,
              kcal: 100,
              proteinG: 5,
              carbsG: 10,
              fatG: 2,
              source: 'manual',
            ),
          ],
          '2026-06-22': [
            const FoodEntry(
              id: 'target-day',
              time: '2026-06-22T20:00:00+02:00',
              desc: 'target day dinner',
              grams: 100,
              kcal: 200,
              proteinG: 10,
              carbsG: 20,
              fatG: 4,
              source: 'manual',
            ),
          ],
        });

        await tester.pumpWidget(
          MaterialApp(
            home: HistoryScreen(
              initialDateRange: DateTimeRange(
                start: DateTime(2026, 6, 22),
                end: DateTime(2026, 6, 22),
              ),
            ),
          ),
        );
        await settle(tester);

        expect(find.text('target day dinner'), findsOneWidget);
        expect(find.text('other day breakfast'), findsNothing);
      });
    },
  );

  // ---------------------------------------------------------------------------
  // applyHistoryFilter — pure function tests (no widget required)
  // ---------------------------------------------------------------------------
}
