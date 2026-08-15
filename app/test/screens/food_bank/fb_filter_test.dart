import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/widgets/food_bank/fb_filter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fb_test_support.dart';

void main() {
  useTempFoodBankStores();
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
}
