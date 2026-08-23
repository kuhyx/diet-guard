/// Offers the day's delivered catering dishes to the log form.
///
/// Its own file because `log_meal_screen.dart` is at the repo's 250-line
/// ceiling.
///
/// **A delivered meal is not an eaten meal.** This only ever *prefills* the
/// form -- the user still taps "Log" for each dish. Nothing here writes a log
/// entry, and nothing here may start doing so: the gate would then satisfy its
/// own checkpoint from a delivery note, and the log would record what the
/// courier dropped off rather than what was eaten.
///
/// [prefillNextDish] is called from **two** places: once when the delivery
/// first arrives, and again after every successful submit. That second caller
/// is the load-bearing one. On the PC it briefly did not exist, which made the
/// "(N more to go)" promise a dead letter -- every dish after the first stayed
/// queued behind another click. `kuchnia_queue_test.dart` asserts the state
/// transition rather than "a dish was offered", because the latter passes
/// while this misbehaves.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/widgets/macro_input_row.dart';
import 'package:flutter/material.dart';

/// Writes [dish]'s name and macros into the log form's controllers.
///
/// Free function rather than a mixin method so the numeric formatting is
/// testable without pumping a widget.
///
/// Clears every macro field first, mirroring `_gatelock_delivery.py`'s
/// `self._clear_inputs()`. Dropping that step is what corrupted a real log
/// entry on 2026-08-23: a dish carries *per-portion* macros and leaves
/// [MacroControllers.perGrams] untouched, so a `100` left behind by an
/// earlier food-bank pick made `nutritionForPortion` read them as *per-100g*
/// and scale them by `grams / 100` -- 472 kcal logged as 1217.8.
///
/// The clear is a single call covering all six controllers rather than a
/// `perGrams.clear()` line here, so a seventh field added later cannot be
/// forgotten at this call site; `MacroControllers.clear()` is enumerated by
/// its own test.
void fillControllersFromDish(
  KuchniaDish dish,
  TextEditingController desc,
  MacroControllers macros,
) {
  macros.clear();
  desc.text = dish.name;
  final (grams, values) = dishFieldValues(dish);
  macros.kcal.text = values.$1;
  macros.protein.text = values.$2;
  macros.carbs.text = values.$3;
  macros.fat.text = values.$4;
  macros.grams.text = grams;
}

/// Wires the catering queue into a log form.
mixin LogMealKuchniaMixin<T extends StatefulWidget> on State<T> {
  /// The dish currently prefilled from the delivery, if any.
  KuchniaDish? offeredDish;

  /// How many delivered dishes still need logging, including the offered one.
  ///
  /// The offered dish counts: it is prefilled, not logged, and the user has
  /// still to tap for it. Excluding it made the line read "0 more" while a
  /// real dish sat in the form.
  int get dishesStillQueued => KuchniaQueueService.remaining;

  /// The form's description field. Supplied by the screen.
  TextEditingController get descController;

  /// The form's macro fields. Supplied by the screen.
  MacroControllers get macroControllers;

  /// Called after the form is filled, so the screen can mark the source.
  void onDishPrefilled() {}

  /// Fills the form's fields from [dish].
  ///
  /// Concrete here rather than an abstract hook: every implementation would be
  /// the same three lines, and the screen file has no budget to spare.
  void fillFormFromDish(KuchniaDish dish) {
    fillControllersFromDish(dish, descController, macroControllers);
    onDishPrefilled();
  }

  /// Loads today's delivery, guarded so it costs at most one walk per day.
  ///
  /// Goes through [KuchniaQueueService.refreshOnce] rather than
  /// `refreshDelivery`: this is an *automatic* trigger and can fire after
  /// every meal, and each unguarded refresh is a login plus three requests
  /// against a third party. The settings button is the explicit ask that
  /// always goes and looks.
  Future<void> loadDeliveryOnce({Set<String> alreadyLogged = const {}}) async {
    if (!KuchniaQueueService.isInitialized) return;
    final result = await KuchniaQueueService.refreshOnce(DateTime.now());
    if (!mounted || result.dishes.isEmpty) return;
    // Ordered by the caterer's own meal priority, against the *user's*
    // schedule -- not a hardcoded four slots. A dish offered for a slot the
    // user's schedule does not have is a checkpoint that can never be met.
    final ordered = dishesInSlotOrder(
      result.dishes,
      daySlots(MealScheduleService.current),
    );
    KuchniaQueueService.instance.offer(ordered, alreadyLogged: alreadyLogged);
    prefillNextDish();
  }

  /// Loads today's delivery, skipping dishes already logged today.
  ///
  /// The skip matters across devices: a dish logged on the PC must not be
  /// offered again here, and the food log is the only record of that.
  Future<void> loadTodaysDelivery() async {
    final logged = await LogStorageService.instance.todayEntries();
    if (!mounted) return;
    await loadDeliveryOnce(
      alreadyLogged: {
        for (final entry in logged) entry.desc.trim().toLowerCase(),
      },
    );
  }

  /// Loads today's delivery on an **explicit** user tap, unguarded.
  ///
  /// Deliberately [refreshDelivery], not [KuchniaQueueService.refreshOnce]:
  /// per `docs/kuchnia-wikinga.md`'s Triggers table, a user who asks gets a
  /// look, the same as the CLI and the settings button. The guard exists to
  /// rate-limit *automatic* triggers, and applying it here would make the
  /// button silently do nothing for the rest of the day after the startup
  /// load — the failure that has nothing to tap in the kitchen.
  ///
  /// Still skips dishes already logged today (a dish logged on the PC must
  /// not be re-offered) and still records the fetch, so a successful tap
  /// also spares the automatic path a second walk.
  ///
  /// Returns a line to show the user, or null when a dish was prefilled and
  /// the form speaks for itself.
  Future<String?> loadDeliveryOnTap() async {
    if (!KuchniaQueueService.isInitialized) return 'Catering is not ready yet.';
    final logged = await LogStorageService.instance.todayEntries();
    if (!mounted) return null;
    final result = await refreshDelivery(DateTime.now());
    if (!mounted) return null;
    if (!result.ok) return result.reason;
    if (result.dishes.isEmpty) return 'No delivery today.';
    await KuchniaQueueService.instance.recordFetched(DateTime.now());
    if (!mounted) return null;
    final ordered = dishesInSlotOrder(
      result.dishes,
      daySlots(MealScheduleService.current),
    );
    KuchniaQueueService.instance.offer(
      ordered,
      alreadyLogged: {
        for (final entry in logged) entry.desc.trim().toLowerCase(),
      },
    );
    if (KuchniaQueueService.next == null) {
      return 'All delivered dishes are already logged.';
    }
    prefillNextDish();
    return null;
  }

  /// Whether an explicit delivery fetch is in flight.
  ///
  /// Only guards against a double tap opening two logins at once -- it is not
  /// the daily guard, which an explicit tap deliberately bypasses.
  bool deliveryBusy = false;

  /// Runs [loadDeliveryOnTap] and shows its outcome as a SnackBar.
  ///
  /// Lives here rather than on the screen because `log_meal_screen.dart` is at
  /// the 250-line cap, and this is the mixin's own behaviour anyway.
  Future<void> loadDeliveryAndReport() async {
    setState(() => deliveryBusy = true);
    String? message;
    try {
      message = await loadDeliveryOnTap();
    } finally {
      if (mounted) setState(() => deliveryBusy = false);
    }
    if (!mounted || message == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Prefills the form with the next queued dish, if there is one.
  ///
  /// Safe to call when the queue is empty: it simply clears the offer.
  void prefillNextDish() {
    final dish = KuchniaQueueService.next;
    if (dish == null) {
      if (offeredDish != null) setState(() => offeredDish = null);
      return;
    }
    setState(() => offeredDish = dish);
    fillFormFromDish(dish);
  }

  /// Drops the just-logged dish and immediately offers the next one.
  ///
  /// Call this from the submit handler *after* the entry is written. This is
  /// the second caller that keeps the queue alive across a submit.
  void advanceQueueAfterLog(String loggedDesc) {
    final dish = offeredDish;
    if (dish == null) return;
    if (dish.name.trim().toLowerCase() != loggedDesc.trim().toLowerCase()) {
      // The user edited the description into something else, so the offered
      // dish was not what they logged. Leave it queued rather than silently
      // marking a dish eaten that never was.
      return;
    }
    KuchniaQueueService.instance.markLogged(dish);
    offeredDish = null;
    prefillNextDish();
  }

  /// A short line naming what is still queued, or null when nothing is.
  ///
  /// The leftover matters: the caterer's five meals against four default slots
  /// means at least one dish is still queued when the last slot is logged. It
  /// is already banked, so it is named rather than dropped silently.
  String? get queueStatusLine {
    final left = dishesStillQueued;
    if (left <= 0) return null;
    return '$left more delivered ${left == 1 ? 'dish' : 'dishes'} to log.';
  }
}
