/// Turns the catering panel's menu payload into [KuchniaDish] records.
///
/// The Dart mirror of `diet_guard/_kuchnia_parse.py`. The shape that matters:
///
/// ```json
/// {"deliveryMenuMeal": [
///     {"mealName": "Śniadanie",
///      "menuMealName": "Marchewkowe pancakes, ...",
///      "mealPriority": 1,
///      "nutrition": {"weight": 270.0, "calories": 435.0, "protein": 25.86,
///                    "carbohydrate": 54.64, "fat": 12.01}},
///     ...]}
/// ```
///
/// **Macros are per portion and `weight` is that portion in grams.** Verified
/// arithmetically rather than assumed. Had they been per-100 g, every imported
/// meal would have been silently wrong by a factor of several -- which is why
/// [parseMenu] drops a dish whose numbers do not hold together instead of
/// importing a plausible-looking lie.
///
/// KEEP IN SYNC WITH `diet_guard/_kuchnia_parse.py`. If the two sides disagree
/// about which dishes pass, each re-adds what the other dropped and the
/// curated bank republishes to every peer on every refresh. Gated by
/// `tests/fixtures/kuchnia_day.json`.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';

/// Atwater factors. Used only as a sanity check on the *units*, never to
/// recompute a value the panel already states.
const double _kcalPerGProtein = 4;
const double _kcalPerGCarb = 4;
const double _kcalPerGFat = 9;

/// How far the macro-derived energy may drift from the stated calories before
/// the dish is treated as unusable.
///
/// Generous by design: the panel rounds, and fibre and polyols carry energy
/// these three factors ignore. A per-100 g mix-up misses by a factor of 2-5,
/// nowhere near this band.
///
/// **This is 0.35, not the "~1%" some prose says** -- that figure describes how
/// closely the captured day happened to agree, not the threshold. Porting 0.01
/// here would drop dishes the PC keeps.
const double kuchniaEnergyTolerance = 0.35;

/// A portion outside this range is not a meal. Guards against a unit change
/// (kg for g) rather than against unusual food.
const double _minGrams = 1;
const double _maxGrams = 5000;

/// Coerces a stored field to `double`, defaulting to 0.
///
/// Mirrors `diet_guard/_coerce.as_float` exactly, and the exactness is
/// load-bearing: bools and **strings** both yield 0. A payload with
/// `"calories": "435"` must be *dropped* by both devices, so this must not
/// reach for `double.tryParse` -- that would keep a dish the PC discards.
double asDouble(Object? value) {
  if (value is bool) return 0;
  if (value is num) return value.toDouble();
  return 0;
}

/// Returns true when the macros roughly account for the stated calories.
///
/// A *unit* check, not a nutrition check: it catches a payload whose macros
/// and calories are quoted on different bases (per portion vs per 100 g),
/// which is the one failure mode that would corrupt every import without
/// looking wrong.
bool energyIsConsistent(double kcal, double protein, double carbs, double fat) {
  if (kcal <= 0) return false;
  final derived =
      _kcalPerGProtein * protein + _kcalPerGCarb * carbs + _kcalPerGFat * fat;
  return (derived - kcal).abs() <= kuchniaEnergyTolerance * kcal;
}

/// Builds one dish, or null when the entry is unusable.
///
/// [fallbackPriority] is the 1-based payload position, used when
/// `mealPriority` is missing.
KuchniaDish? parseMeal(Object? meal, int fallbackPriority) {
  if (meal is! Map) return null;
  final nutrition = meal['nutrition'];
  if (nutrition is! Map) return null;

  // `menuMealName` is the dish; `mealName` is the slot label ("Kolacja"),
  // which would collapse every Monday dinner onto one bank entry.
  final rawName = meal['menuMealName'];
  final name = rawName is String ? rawName.trim() : '';
  if (name.isEmpty) return null;

  final kcal = asDouble(nutrition['calories']);
  final protein = asDouble(nutrition['protein']);
  final carbs = asDouble(nutrition['carbohydrate']);
  final fat = asDouble(nutrition['fat']);
  final grams = asDouble(nutrition['weight']);

  if (grams < _minGrams || grams > _maxGrams) return null;
  if (!energyIsConsistent(kcal, protein, carbs, fat)) return null;

  // Python rejects bools here (they are an int subclass); Dart's `is int` is
  // already false for a bool, so the check is naturally equivalent.
  final rawPriority = meal['mealPriority'];
  final priority = rawPriority is int ? rawPriority : fallbackPriority;

  final rawLabel = meal['mealName'];
  return KuchniaDish(
    name: name,
    kcal: kcal,
    proteinG: protein,
    carbsG: carbs,
    fatG: fat,
    grams: grams,
    priority: priority,
    slotLabel: rawLabel is String ? rawLabel.trim() : '',
  );
}

/// Extracts the day's dishes from a `menus/delivery/{id}/new` response.
///
/// Unusable entries are skipped rather than thrown on: a single malformed dish
/// must not cost the user the other four. Returns the dishes in payload order;
/// `kuchnia_spread.dart` sorts them by priority.
List<KuchniaDish> parseMenu(Object? payload) {
  if (payload is! Map) return const [];
  final meals = payload['deliveryMenuMeal'];
  if (meals is! List) return const [];
  final dishes = <KuchniaDish>[];
  for (var index = 0; index < meals.length; index++) {
    final dish = parseMeal(meals[index], index + 1);
    if (dish != null) dishes.add(dish);
  }
  return dishes;
}
