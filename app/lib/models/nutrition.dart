/// Per-portion macro estimate, mirroring diet_guard's Python `Nutrition`.
library;

/// Estimated calories and macros for a logged or in-progress portion.
///
/// Field names match diet_guard's `_estimator.Nutrition` dataclass exactly
/// (`kcal`, `proteinG`, `carbsG`, `fatG`, `grams`, `source`) so JSON written
/// by this app round-trips through the PC app's schema with no translation.
class Nutrition {
  /// Creates a [Nutrition] from its macro fields and provenance label.
  const Nutrition({
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.grams,
    required this.source,
  });

  /// Calories for the portion.
  final double kcal;

  /// Protein in grams.
  final double proteinG;

  /// Carbohydrate in grams.
  final double carbsG;

  /// Fat in grams.
  final double fatG;

  /// Portion weight in grams (0 when unknown).
  final double grams;

  /// Where these macros came from (e.g. `"manual"`, `"food bank"`).
  final String source;
}

/// Rescales [nutrition] to a new portion weight in [grams] (pure).
///
/// Mirrors `_estimator.scale_nutrition`: a stored or typed macro set
/// describes *some* basis portion (`nutrition.grams`), and eating a
/// different amount scales every macro proportionally. When the basis
/// weight or [grams] is unknown (`<= 0`), there is nothing to scale from,
/// so the macros are kept and only the recorded weight is updated.
Nutrition scaleNutrition(Nutrition nutrition, double grams) {
  if (nutrition.grams <= 0 || grams <= 0) {
    return Nutrition(
      kcal: nutrition.kcal,
      proteinG: nutrition.proteinG,
      carbsG: nutrition.carbsG,
      fatG: nutrition.fatG,
      grams: grams > 0 ? grams : nutrition.grams,
      source: nutrition.source,
    );
  }
  final factor = grams / nutrition.grams;
  double scale(double value) =>
      double.parse((value * factor).toStringAsFixed(1));
  return Nutrition(
    kcal: scale(nutrition.kcal),
    proteinG: scale(nutrition.proteinG),
    carbsG: scale(nutrition.carbsG),
    fatG: scale(nutrition.fatG),
    grams: grams,
    source: nutrition.source,
  );
}

/// Builds the eaten-portion [Nutrition] from typed macros that may describe
/// a different reference weight than what was actually eaten -- e.g. "250
/// kcal per 100 g, I ate 150 g" -- mirroring `_resolve.resolve_nutrition`'s
/// manual-macro branch so both apps compute portions identically.
///
/// Leaving [perGrams] at 0 means the typed macros already describe the
/// full eaten portion (the original, pre-scaling behaviour); leaving
/// [ateGrams] at 0 assumes the eaten amount equals [perGrams].
Nutrition nutritionForPortion({
  required double kcal,
  required double proteinG,
  required double carbsG,
  required double fatG,
  required double perGrams,
  required double ateGrams,
  required String source,
}) {
  final referenceGrams = perGrams > 0 ? perGrams : ateGrams;
  final eatenGrams = ateGrams > 0 ? ateGrams : referenceGrams;
  final reference = Nutrition(
    kcal: kcal,
    proteinG: proteinG,
    carbsG: carbsG,
    fatG: fatG,
    grams: referenceGrams,
    source: source,
  );
  return scaleNutrition(reference, eatenGrams);
}
