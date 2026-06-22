/// Composite "meal" support, mirroring diet_guard's `_meal.py`.
library;

import 'package:diet_guard_app/models/meal_component.dart';
import 'package:diet_guard_app/models/nutrition.dart';

/// Provenance stamped on a summed meal, matching `_meal.MEAL_SOURCE`.
const String mealSource = 'meal';

/// One named component of a composite meal, with its own nutrition.
///
/// Mirrors `_meal.MealItem`.
class MealItem {
  /// Creates a [MealItem] from a component's name and resolved macros.
  const MealItem({required this.name, required this.nutrition});

  /// The component's food name (e.g. `"chicken"`).
  final String name;

  /// The component's resolved macros for the amount eaten.
  final Nutrition nutrition;
}

/// Returns the summed nutrition of a meal's [items].
///
/// Every macro and the portion weight are added across the items and
/// rounded to 0.1, and the result is stamped `source: mealSource` so it is
/// distinguishable from a single food. Mirrors `_meal.meal_total`.
Nutrition mealTotal(List<MealItem> items) {
  double sumOf(double Function(MealItem) field) {
    var total = 0.0;
    for (final item in items) {
      total += field(item);
    }
    return double.parse(total.toStringAsFixed(1));
  }

  return Nutrition(
    kcal: sumOf((item) => item.nutrition.kcal),
    proteinG: sumOf((item) => item.nutrition.proteinG),
    carbsG: sumOf((item) => item.nutrition.carbsG),
    fatG: sumOf((item) => item.nutrition.fatG),
    grams: sumOf((item) => item.nutrition.grams),
    source: mealSource,
  );
}

/// Returns a composite meal's per-component log record for [item].
///
/// Carries the component's full macros (not just its name) so a food bank
/// rebuilt purely by replaying the log can recover each component's
/// standalone nutrition, not just the composite's summed total. Mirrors
/// `_meal.item_to_component`.
MealComponent itemToComponent(MealItem item) => MealComponent(
  name: item.name,
  kcal: item.nutrition.kcal,
  proteinG: item.nutrition.proteinG,
  carbsG: item.nutrition.carbsG,
  fatG: item.nutrition.fatG,
  grams: item.nutrition.grams,
);
