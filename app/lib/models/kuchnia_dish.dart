/// One delivered catering dish, with its portion macros.
///
/// The Dart mirror of `diet_guard/_kuchnia_parse.py`'s `Dish`. Every macro is
/// the total *for this portion*, not per 100 g -- the same convention
/// [Nutrition] uses.
///
/// KEEP IN SYNC WITH `diet_guard/_kuchnia_parse.py`. Both sides are gated by
/// `tests/fixtures/kuchnia_day.json`; see `kuchnia_parity_test.dart`.
library;

/// A dish the caterer delivered on a given day.
class KuchniaDish {
  /// Creates a dish from its already-validated fields.
  const KuchniaDish({
    required this.name,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.grams,
    required this.priority,
    required this.slotLabel,
  });

  /// The dish itself (`menuMealName`), e.g. "Kaszotto grzybowe...".
  ///
  /// Not `mealName`, which is the slot label ("Kolacja") and would collapse
  /// every Monday dinner onto one food-bank entry.
  final String name;

  /// Calories for this portion.
  final double kcal;

  /// Protein in grams, for this portion.
  final double proteinG;

  /// Carbohydrate in grams, for this portion.
  final double carbsG;

  /// Fat in grams, for this portion.
  final double fatG;

  /// The portion weight in grams (`nutrition.weight`).
  final double grams;

  /// The caterer's own eating order, 1..N.
  ///
  /// Falls back to the dish's 1-based position in the payload when
  /// `mealPriority` is missing.
  final int priority;

  /// The caterer's slot label ("Śniadanie", "Obiad", ...), for display only.
  final String slotLabel;

  /// The curated-bank record for this dish.
  ///
  /// Mirrors `_kuchnia_import.dish_to_record`. `count` is 0: the bank's count
  /// ranks foods by how often they were *eaten*, and a delivered dish has not
  /// been eaten yet.
  ///
  /// Every macro is forced to `double` before it reaches `jsonEncode`.
  /// `jsonEncode(435)` emits `435` where Python emits `435.0`, and a
  /// byte-different record for the same dish makes every refresh look like a
  /// change -- which republishes the whole curated bank to every peer.
  Map<String, dynamic> toBankRecord() => {
    'desc': name,
    'kcal': kcal.toDouble(),
    'protein_g': proteinG.toDouble(),
    'carbs_g': carbsG.toDouble(),
    'fat_g': fatG.toDouble(),
    'grams': grams.toDouble(),
    'count': 0,
  };

  /// The curated bank's key for this dish.
  ///
  /// Python uses `str.casefold()` and this uses `String.toLowerCase()`. They
  /// agree across the whole Polish alphabet and diverge only on `ß`,
  /// ligatures and final sigma; rekeying to unify them would strand every
  /// existing entry, so the agreement is pinned by test instead.
  String get bankKey => name.trim().toLowerCase();
}
