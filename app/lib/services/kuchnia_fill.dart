/// "Fill all with catering": which delivered dishes go into today's log.
///
/// The Dart mirror of `diet_guard/_kuchnia_log.py`'s `fill_plan` and
/// `log_dishes`. KEEP IN SYNC, gated by the shared parity fixture.
///
/// **Nothing here runs without an explicit confirm tap.** A delivered meal is
/// not an eaten meal: logging unattended would let the delivery note satisfy
/// the very checkpoints the gate exists to enforce. [logDishes] is only ever
/// reached from the second tap of `FillAllFlow`.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';

/// Marks entries this feature created, the same tag the PC's Fill all writes
/// (`_kuchnia_log.SOURCE`), so both devices' batch fills read alike.
const kuchniaSource = 'kuchnia wikinga';

/// Keeps only the dishes whose slot has nothing logged in it today.
///
/// Fills *empty* slots: a slot the user already logged something into keeps
/// that meal rather than gaining a second one. [occupied] is read once, before
/// the batch, so two dishes the spread put in the same empty slot (5 dishes on
/// 4 slots) both land.
///
/// Pure, unlike Python's `fill_plan` which reads `today_entries()` itself:
/// the caller passes occupancy so the rule is testable without storage.
List<SlottedDish> fillPlan(List<SlottedDish> slotted, Set<int> occupied) => [
  for (final item in slotted)
    if (!occupied.contains(item.slot)) item,
];

/// Returns [dish] as the whole-portion [Nutrition] it gets logged as.
///
/// Goes through [nutritionForPortion] with no "per" basis -- exactly what the
/// "Today's delivery" prefill does when its form is submitted -- so a filled
/// entry is indistinguishable from a prefilled one (including its 0.1 g
/// rounding), apart from [kuchniaSource].
Nutrition dishNutrition(KuchniaDish dish) => nutritionForPortion(
  kcal: dish.kcal,
  proteinG: dish.proteinG,
  carbsG: dish.carbsG,
  fatG: dish.fatG,
  perGrams: 0,
  ateGrams: dish.grams,
  source: kuchniaSource,
);

String _dedupKey(String desc, int? slot) =>
    '${desc.trim().toLowerCase()}\u0000$slot';

/// Logs each chosen dish, skipping any already logged today in that slot.
///
/// Mirrors `log_dishes`, including its intra-batch skip: two identical dishes
/// spread into the same slot land once, because the write is reflected in the
/// seen set before the next dish is checked.
///
/// Writes through [LogStorageService.logMeal], the same call a manual log
/// makes; the caller then publishes once for the whole batch.
///
/// Returns the dishes actually written, in order.
Future<List<SlottedDish>> logDishes(
  List<SlottedDish> chosen, {
  LogStorageService? storage,
}) async {
  final store = storage ?? LogStorageService.instance;
  final seen = {
    for (final entry in await store.todayEntries())
      _dedupKey(entry.desc, entry.slot),
  };
  final written = <SlottedDish>[];
  for (final item in chosen) {
    final key = _dedupKey(item.dish.name, item.slot);
    if (!seen.add(key)) continue;
    await store.logMeal(
      item.dish.name,
      dishNutrition(item.dish),
      slot: item.slot,
    );
    written.add(item);
  }
  return written;
}

/// Formats like Python's `f"{value:g}"` for the values a menu carries:
/// "435" rather than "435.0", one decimal otherwise.
String _g(double value) {
  final fixed = value.toStringAsFixed(1);
  return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
}

/// The proposal line shown after the first tap, as on the PC gate.
String planSummary(List<SlottedDish> plan) {
  final total = plan.fold<double>(0, (sum, item) => sum + item.dish.kcal);
  final listing = plan
      .map(
        (item) =>
            '${item.slot.toString().padLeft(2, '0')}:00 '
            '${item.dish.name}',
      )
      .join(', ');
  return 'Will log ${plan.length} (${_g(total)} kcal): $listing'
      ' — tap Confirm.';
}
