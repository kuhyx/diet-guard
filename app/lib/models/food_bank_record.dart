/// One entry in the local food bank (autocomplete index), mirroring
/// diet_guard's `_foodbank.BankRecord`.
library;

/// A previously-logged (or hand-curated) food's macros and use count.
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
    this.editedAt,
  });

  /// Builds a [FoodBankRecord] from its JSON map representation.
  ///
  /// Every field is type-*checked* rather than cast. These maps now arrive
  /// from another device over the network, and a bad cast here throws a
  /// Dart `TypeError` -- an `Error`, not an `Exception` -- which sails
  /// straight past the `on Exception` guards in `background_sync_service`
  /// and `settings_screen`. One malformed record in the shared repo would
  /// otherwise break this device's sync permanently. Mirrors the `isinstance`
  /// checks the Python side already uses.
  factory FoodBankRecord.fromJson(Map<String, dynamic> json) {
    double number(Object? value) => value is num ? value.toDouble() : 0;
    final components = json['components'];
    return FoodBankRecord(
      desc: json['desc'] is String ? json['desc'] as String : '',
      kcal: number(json['kcal']),
      proteinG: number(json['protein_g']),
      carbsG: number(json['carbs_g']),
      fatG: number(json['fat_g']),
      grams: number(json['grams']),
      count: number(json['count']),
      components: components is List
          ? components.whereType<String>().toList()
          : null,
      editedAt: json['t'] is String ? json['t'] as String : null,
    );
  }

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

  /// Local ISO-8601 stamp of the last hand-edit, for curated entries only.
  ///
  /// Null on log-derived records: those are rebuilt from the (already synced)
  /// log and need no clock of their own. On a curated entry it is what the
  /// cross-device merge orders by -- see `foodbank_manual_sync`.
  final String? editedAt;

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
    if (editedAt != null) 't': editedAt,
  };
}
