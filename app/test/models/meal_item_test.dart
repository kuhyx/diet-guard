import 'package:diet_guard_app/models/meal_item.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:flutter_test/flutter_test.dart';

Nutrition _n(double kcal, double protein, double carbs, double fat, double g) =>
    Nutrition(
      kcal: kcal,
      proteinG: protein,
      carbsG: carbs,
      fatG: fat,
      grams: g,
      source: 'manual',
    );

void main() {
  group('mealTotal', () {
    test('sums every macro and the portion weight across items', () {
      final items = [
        MealItem(name: 'soup', nutrition: _n(100, 5, 10, 2, 200)),
        MealItem(name: 'chicken', nutrition: _n(250, 30, 0, 10, 150)),
      ];
      final total = mealTotal(items);
      expect(total.kcal, 350);
      expect(total.proteinG, 35);
      expect(total.carbsG, 10);
      expect(total.fatG, 12);
      expect(total.grams, 350);
      expect(total.source, mealSource);
    });

    test('returns all zeros for an empty meal', () {
      final total = mealTotal(const []);
      expect(total.kcal, 0);
      expect(total.grams, 0);
      expect(total.source, mealSource);
    });

    test('rounds the summed values to 0.1', () {
      final items = [
        MealItem(name: 'a', nutrition: _n(1.05, 1.05, 1.05, 1.05, 1.05)),
        MealItem(name: 'b', nutrition: _n(1.05, 1.05, 1.05, 1.05, 1.05)),
      ];
      final total = mealTotal(items);
      expect(total.kcal, 2.1);
    });
  });

  group('itemToComponent', () {
    test('carries the item\'s name and full macros', () {
      final item = MealItem(name: 'rice', nutrition: _n(200, 4, 44, 1, 150));
      final component = itemToComponent(item);
      expect(component.name, 'rice');
      expect(component.kcal, 200);
      expect(component.proteinG, 4);
      expect(component.carbsG, 44);
      expect(component.fatG, 1);
      expect(component.grams, 150);
    });
  });
}
