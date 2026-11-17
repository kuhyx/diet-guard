/// Logs the delivered catering dishes of the due slots, without a tap.
///
/// kuhy overrode the old "delivered is not eaten, so never log unattended"
/// rule on 2026-11-17 ("LOG EVEN WITHOUT TAP"). The screen calls [logDue] when
/// it opens or resumes with a slot due; the plan is the fill-all plan
/// (`assignSlots` by the caterer's `mealPriority`, `fillPlan` over occupied
/// slots) minus the confirm tap, restricted to the due slots.
///
/// **Ids are deterministic** so a repeat open and every other device collapse
/// to one entry on merge: UUID v5 over the RFC 4122 URL namespace of
/// `kuchnia:<delivery date YYYY-MM-DD>:<dish key>`. The shared fixture
/// `tests/fixtures/kuchnia_autolog_ids.json` pins them for both languages.
/// An undone dish keeps its tombstone, so it is never logged a second time.
///
/// The fetch is a third-party login, so the day's dishes are cached in memory
/// and a failed or empty fetch is retried at most every [retryAfter].
/// `KuchniaQueueService.refreshOnce` cannot serve here: after the first clean
/// fetch of the day it returns nothing, and slots that fall due later would
/// never see their dish.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/kuchnia_dish.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_fill_flow.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_entry_lookup.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';

/// The id of the entry that logs [dish] for [deliveryDate] (`YYYY-MM-DD`).
String kuchniaAutologId(String deliveryDate, KuchniaDish dish) => const Uuid()
    .v5(Namespace.url.value, 'kuchnia:$deliveryDate:${dish.autologKey}');

/// Logs delivered dishes for due slots. One per process is plenty.
class KuchniaAutoLog {
  /// Creates the service; every dependency is injectable for tests.
  KuchniaAutoLog({
    DeliveryFetch? fetch,
    DateTime Function()? now,
    this.retryAfter = const Duration(minutes: 10),
  }) : _fetch = fetch ?? refreshDelivery,
       _now = now ?? DateTime.now;

  /// The process-wide instance the screen uses.
  static KuchniaAutoLog instance = KuchniaAutoLog();

  /// Minimum gap between fetches that found nothing or failed.
  final Duration retryAfter;

  final DeliveryFetch _fetch;
  final DateTime Function() _now;
  String? _cachedDay;
  List<KuchniaDish> _cachedDishes = const [];
  DateTime? _lastEmptyFetch;
  Future<List<FoodEntry>>? _inFlight;

  /// Forgets the cache, so the next call fetches again (tests, day change).
  @visibleForTesting
  void reset() {
    _cachedDay = null;
    _cachedDishes = const [];
    _lastEmptyFetch = null;
  }

  /// Logs the dishes assigned to [dueSlots]; returns the entries it wrote.
  ///
  /// Single-flight: a second call while one runs joins it, so an open and a
  /// resume racing each other cannot interleave two read-modify-writes.
  Future<List<FoodEntry>> logDue(List<int> dueSlots) =>
      _inFlight ??= _run(dueSlots).whenComplete(() => _inFlight = null);

  Future<List<FoodEntry>> _run(List<int> dueSlots) async {
    if (dueSlots.isEmpty) return const [];
    final today = _now();
    final dayKey = localDateKey(today);
    final dishes = await _dishesFor(today, dayKey);
    if (dishes.isEmpty) return const [];
    final store = LogStorageService.instance;
    final slots = daySlots(MealScheduleService.history.forDay(dayKey));
    final plan = fillPlan(
      assignSlots(dishes, slots),
      await loggedSlotsOn(store, today),
    ).where((item) => dueSlots.contains(item.slot)).toList();
    String idFor(SlottedDish item) => kuchniaAutologId(dayKey, item.dish);
    final written = await logDishes(plan, storage: store, idFor: idFor);
    return [for (final item in written) ?await store.findEntry(idFor(item))];
  }

  Future<List<KuchniaDish>> _dishesFor(DateTime today, String dayKey) async {
    if (_cachedDay == dayKey) return _cachedDishes;
    final last = _lastEmptyFetch;
    if (last != null && _now().difference(last) < retryAfter) return const [];
    final result = await _fetch(today);
    if (result.ok && result.dishes.isNotEmpty) {
      _cachedDay = dayKey;
      return _cachedDishes = result.dishes;
    }
    _lastEmptyFetch = _now();
    return const [];
  }
}
