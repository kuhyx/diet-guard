import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/widgets/history/history_filter.dart';
import 'package:diet_guard_app/widgets/history/history_grouping.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'history_test_support.dart';

void main() {
  useTempHistoryStores();
  group('applyHistoryFilter', () {
    final entries = [
      const FoodEntry(
        id: 'a',
        time: '2026-06-20T08:00:00+02:00',
        desc: 'Apple',
        grams: 100,
        kcal: 80,
        proteinG: 0.5,
        carbsG: 20,
        fatG: 0.3,
        source: 'manual',
      ),
      const FoodEntry(
        id: 'b',
        time: '2026-06-21T12:00:00+02:00',
        desc: 'Banana smoothie',
        grams: 250,
        kcal: 200,
        proteinG: 3,
        carbsG: 40,
        fatG: 1,
        source: 'food bank',
      ),
      const FoodEntry(
        id: 'c',
        time: '2026-06-22T20:00:00+02:00',
        desc: 'Chicken breast',
        grams: 150,
        kcal: 230,
        proteinG: 45,
        carbsG: 0,
        fatG: 5,
        source: 'meal',
      ),
    ];

    test('no filter returns all entries sorted by date descending', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(),
        HistorySortField.date,
        ascending: false,
      );
      expect(result.map((e) => e.id), ['c', 'b', 'a']);
    });

    test('nameQuery filters by case-insensitive substring', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(nameQuery: 'an'),
        HistorySortField.date,
        ascending: false,
      );
      expect(result.map((e) => e.id), ['b']); // 'Banana smoothie'
    });

    test('minKcal and maxKcal filter by kcal range', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(minKcal: 100, maxKcal: 210),
        HistorySortField.date,
        ascending: false,
      );
      expect(result.map((e) => e.id), ['b']); // 200 kcal
    });

    test('minProtein filters by protein', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(minProtein: 10),
        HistorySortField.date,
        ascending: false,
      );
      expect(result.map((e) => e.id), ['c']); // 45g protein
    });

    test('maxCarbs filters by carbs', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(maxCarbs: 5),
        HistorySortField.date,
        ascending: false,
      );
      expect(result.map((e) => e.id), ['c']); // 0 carbs
    });

    test('minFat and maxFat filter by fat', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(minFat: 0.4, maxFat: 2),
        HistorySortField.date,
        ascending: false,
      );
      expect(result.map((e) => e.id), ['b']); // fat=1
    });

    test('source filter keeps only matching source', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(source: 'meal'),
        HistorySortField.date,
        ascending: false,
      );
      expect(result.map((e) => e.id), ['c']);
    });

    test('dateRange filter includes only entries within range', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(
          dateRange: DateTimeRange(
            start: DateTime(2026, 6, 21),
            end: DateTime(2026, 6, 21),
          ),
        ),
        HistorySortField.date,
        ascending: false,
      );
      expect(result.map((e) => e.id), ['b']);
    });

    test('sort ascending by kcal', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(),
        HistorySortField.kcal,
        ascending: true,
      );
      expect(result.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('sort descending by protein', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(),
        HistorySortField.protein,
        ascending: false,
      );
      expect(result.first.id, 'c'); // 45g
    });

    test('sort by description ascending', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(),
        HistorySortField.description,
        ascending: true,
      );
      // Apple, Banana smoothie, Chicken breast
      expect(result.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('sort by fat', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(),
        HistorySortField.fat,
        ascending: true,
      );
      expect(result.first.id, 'a'); // fat=0.3
    });

    test('sort by carbs descending', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(),
        HistorySortField.carbs,
        ascending: false,
      );
      expect(result.first.id, 'b'); // 40g carbs
    });

    test('HistoryFilter.isActive is false when nothing is set', () {
      expect(HistoryFilter().isActive, isFalse);
    });

    test('HistoryFilter.isActive is true when nameQuery is set', () {
      expect(HistoryFilter(nameQuery: 'x').isActive, isTrue);
    });

    test('HistoryFilter.isActive is true when source is set', () {
      expect(HistoryFilter(source: 'manual').isActive, isTrue);
    });

    test('maxProtein filters by protein', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(maxProtein: 5),
        HistorySortField.date,
        ascending: false,
      );
      // Apple (0.5 g) and Banana (3 g) have protein ≤ 5 g.
      expect(result.map((e) => e.id), ['b', 'a']);
    });

    test('minCarbs filters by carbs', () {
      final result = applyHistoryFilter(
        entries,
        HistoryFilter(minCarbs: 15),
        HistorySortField.date,
        ascending: false,
      );
      // Banana (40 g) and Apple (20 g) have carbs ≥ 15 g.
      expect(result.map((e) => e.id), ['b', 'a']);
    });
  });

  // ---------------------------------------------------------------------------
  // Widget-level — day grouping and filter badge
  // ---------------------------------------------------------------------------
}
