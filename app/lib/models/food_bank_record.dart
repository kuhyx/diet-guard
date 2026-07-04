/// One entry in the local food bank (autocomplete index), mirroring
/// diet_guard's `_foodbank.BankRecord`.
library;

/// A previously-logged food's remembered macros and use count.
///
/// Mirrors `_foodbank.py`'s on-disk shape: `{desc, kcal, protein_g,
/// carbs_g, fat_g, grams, count, components?}`. Unlike [FoodEntry], a
/// composite record's `components` here are bare names (the bank is an
/// autocomplete index, not the source of truth for component macros --
/// those live on the log entry itself, see `MealComponent`).
class FoodBankRecord {
  /// Creates a [FoodBankRecord] from its stored fields.
  const FoodBankRecord({
    required this.desc,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.grams,
    required this.count,
    this.components,
  });

  /// Builds a [FoodBankRecord] from its JSON map representation.
  factory FoodBankRecord.fromJson(Map<String, dynamic> json) => FoodBankRecord(
    desc: json['desc'] as String? ?? '',
    kcal: (json['kcal'] as num?)?.toDouble() ?? 0,
    proteinG: (json['protein_g'] as num?)?.toDouble() ?? 0,
    carbsG: (json['carbs_g'] as num?)?.toDouble() ?? 0,
    fatG: (json['fat_g'] as num?)?.toDouble() ?? 0,
    grams: (json['grams'] as num?)?.toDouble() ?? 0,
    count: (json['count'] as num?)?.toDouble() ?? 0,
    components: (json['components'] as List?)?.cast<String>(),
  );

  /// The food or meal's display name, as the user typed it.
  final String desc;

  /// Calories per the stored portion.
  final double kcal;

  /// Protein in grams.
  final double proteinG;

  /// Carbohydrate in grams.
  final double carbsG;

  /// Fat in grams.
  final double fatG;

  /// Portion weight in grams.
  final double grams;

  /// Number of times this food has been logged (ranks staples first).
  final double count;

  /// Component names, for a composite meal record only.
  final List<String>? components;

  /// Returns this record as a JSON-ready map with snake_case keys.
  Map<String, Object?> toJson() => {
    'desc': desc,
    'kcal': kcal,
    'protein_g': proteinG,
    'carbs_g': carbsG,
    'fat_g': fatG,
    'grams': grams,
    'count': count,
    if (components != null) 'components': components,
  };
}
