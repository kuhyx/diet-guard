/// A composite meal's per-component record, carried on a log entry.
library;

/// One component's name and macros, as stored on a composite log entry's
/// `components` list.
///
/// Mirrors the dict shape `_meal.item_to_component` builds on the Python
/// side: `{name, kcal, protein_g, carbs_g, fat_g, grams}`. Carrying full
/// macros (not just the name) lets a food bank rebuilt purely by replaying
/// the log recover each component's standalone nutrition, not just the
/// composite's summed total.
class MealComponent {
  /// Creates a [MealComponent] from its name and macro fields.
  const MealComponent({
    required this.name,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.grams,
  });

  /// Builds a [MealComponent] from its JSON map representation.
  factory MealComponent.fromJson(Map<String, dynamic> json) => MealComponent(
    name: json['name'] as String? ?? '',
    kcal: (json['kcal'] as num?)?.toDouble() ?? 0,
    proteinG: (json['protein_g'] as num?)?.toDouble() ?? 0,
    carbsG: (json['carbs_g'] as num?)?.toDouble() ?? 0,
    fatG: (json['fat_g'] as num?)?.toDouble() ?? 0,
    grams: (json['grams'] as num?)?.toDouble() ?? 0,
  );

  /// The component's food name (e.g. `"chicken"`).
  final String name;

  /// Calories for this component's portion.
  final double kcal;

  /// Protein in grams.
  final double proteinG;

  /// Carbohydrate in grams.
  final double carbsG;

  /// Fat in grams.
  final double fatG;

  /// Portion weight in grams.
  final double grams;

  /// Returns this component as a JSON-ready map with snake_case keys.
  Map<String, Object?> toJson() => {
    'name': name,
    'kcal': kcal,
    'protein_g': proteinG,
    'carbs_g': carbsG,
    'fat_g': fatG,
    'grams': grams,
  };
}
