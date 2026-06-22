/// An autocomplete result, mirroring `_foodbank.search_foods`'s return type.
library;

import 'package:diet_guard_app/models/nutrition.dart';

/// One ranked autocomplete suggestion: a display name and its macros.
class FoodSuggestion {
  /// Creates a [FoodSuggestion] from its display name and macros.
  const FoodSuggestion({required this.name, required this.nutrition});

  /// The food or meal's display name.
  final String name;

  /// The food or meal's stored macros.
  final Nutrition nutrition;
}
