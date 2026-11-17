/// "Fill all with catering": which delivered dishes go into today's log.
///
/// The Dart mirror of `diet_guard/_kuchnia_log.py`'s `fill_plan` and
/// `log_dishes`. KEEP IN SYNC, gated by the shared parity fixture.
///
/// **Delivered counts as eaten (override, 2026-11-17).** The old rule was "a
/// delivered meal is not an eaten meal, so nothing logs without a confirm
/// tap". kuhy overrode it ("LOG EVEN WITHOUT TAP"): [logDishes] is now also
/// reached unattended from `kuchnia_autolog.dart`, which logs the dishes of the
/// slots that are due when the app opens. Every such entry has a deterministic
/// id and shows an undo row, so a skipped or binned meal is one tap to remove.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_entry_lookup.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';

/// Marks entries this feature created, the same tag the PC's Fill all writes
/// (`_kuchnia_log.SOURCE`), so both devices' batch fills read alike.
const kuchniaSource = 'kuchnia wikinga';

/// Keeps only the dishes whose slot has nothing logged in it today.
///
/// [occupied] holds slot minutes *satisfied* today (see
/// `LogStorageService.loggedSlotsToday`), i.e. entries already snapped to
/// the nearest current slot -- not raw recorded minutes, or a meal logged
/// under yesterday's schedule would leave its slot looking empty.
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

/// Keyed by the entry's *recorded* slot minute, unsnapped, mirroring Python's
/// `_already_logged` exact comparison. Deliberately not snapped: occupancy
/// ([fillPlan]) already snaps, so this only has to catch the exact dish this
/// batch or an earlier fill wrote into the same slot.
String _dedupKey(String desc, int? slotMinute) =>
    '${desc.trim().toLowerCase()}\u0000$slotMinute';

/// Returns [day]'s live entries; today's when [day] is null.
Future<List<FoodEntry>> dayEntries(
  LogStorageService store,
  DateTime? day,
) async {
  if (day == null) return await store.todayEntries();
  final log = await store.readLog();
  return [
    for (final entry in log[localDateKey(day)] ?? const <FoodEntry>[])
      if (!entry.deleted) entry,
  ];
}

/// [day]'s satisfied slot minutes under the schedule in force *that* day --
/// `LogStorageService.loggedSlotsToday` for any date, as the "Log for later"
/// slot row computes it.
Future<Set<int>> loggedSlotsOn(LogStorageService store, DateTime day) async {
  final entries = await dayEntries(store, day);
  return satisfiedSlots([
    for (final entry in entries) ?entry.slotMinute,
  ], MealScheduleService.history.forDay(localDateKey(day)));
}

/// Logs each chosen dish, skipping any already logged that day in that slot.
///
/// Mirrors `log_dishes`, including its intra-batch skip: two identical dishes
/// spread into the same slot land once, because the write is reflected in the
/// seen set before the next dish is checked.
///
/// Writes through [LogStorageService.logMeal], the same call a manual log
/// makes; the caller then publishes once for the whole batch. With [day]
/// (a "Log for later" date, strictly after today) each dish is stamped at its
/// slot's time on that day; without it, now -- as a manual log is.
///
/// [idFor] gives each dish a deterministic entry id (see
/// `kuchniaAutologId`); a dish whose id is already in the log is skipped.
///
/// Returns the dishes actually written, in order.
Future<List<SlottedDish>> logDishes(
  List<SlottedDish> chosen, {
  LogStorageService? storage,
  DateTime? day,
  String Function(SlottedDish item)? idFor,
}) async {
  final store = storage ?? LogStorageService.instance;
  final seen = {
    for (final entry in await dayEntries(store, day))
      _dedupKey(entry.desc, entry.slotMinute),
  };
  // Tombstones included: an undone auto-logged dish must stay undone.
  final knownIds = idFor == null ? const <String>{} : await store.allEntryIds();
  final written = <SlottedDish>[];
  for (final item in chosen) {
    final id = idFor?.call(item);
    if (id != null && knownIds.contains(id)) continue;
    final key = _dedupKey(item.dish.name, item.slot);
    if (!seen.add(key)) continue;
    await store.logMeal(
      item.dish.name,
      dishNutrition(item.dish),
      slotMinute: item.slot,
      id: id,
      when: day == null
          ? null
          : DateTime(
              day.year,
              day.month,
              day.day,
              item.slot ~/ 60,
              item.slot % 60,
            ),
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
      .map((item) => '${slotLabel(item.slot)} ${item.dish.name}')
      .join(', ');
  return 'Will log ${plan.length} (${_g(total)} kcal): $listing'
      ' — tap Confirm.';
}
