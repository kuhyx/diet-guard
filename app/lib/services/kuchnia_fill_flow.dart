/// The two-tap state machine behind "Fill all with catering".
///
/// Mirrors `diet_guard/_gatelock_fillall.py`'s `FillAllFlow`. Two taps, never
/// one: the first fetches the day's delivery (today's, or the date picked
/// through "Log for later") and proposes exactly what would be written; only
/// the second writes. No modal dialog -- the proposal is a status line and
/// the button relabels to "✓ Confirm (N)".
///
/// Widget-free so the flow's guarantees (first tap writes nothing, confirm
/// re-checks occupancy, a plan from before midnight refetches) are testable
/// with an injected clock and fetch.
library;

import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Fetches one day's delivery.
typedef DeliveryFetch = Future<KuchniaRefresh> Function(DateTime day);

/// What one tap produced: a line for the user, and what (if anything) landed.
typedef FillOutcome = ({String message, List<SlottedDish> written});

/// The empty "nothing written" half of a [FillOutcome].
const _none = <SlottedDish>[];

/// The status line when every slot the delivery covers already holds a meal.
const nothingToFillMessage = 'Every slot already has a meal — nothing to fill.';

/// The explicit tap's fetch: unguarded, like "Today's delivery", and it
/// records today's fetch so the automatic path is spared a second walk.
///
/// Only today's: the marker holds a single day, so recording a "Log for
/// later" date would make the automatic fetch skip that day when it comes.
@visibleForTesting
Future<KuchniaRefresh> fetchAndRecord(
  DateTime day, {
  DeliveryFetch fetch = refreshDelivery,
}) async {
  final result = await fetch(day);
  if (result.ok &&
      result.dishes.isNotEmpty &&
      localDateKey(day) == localDateKey(DateTime.now()) &&
      KuchniaQueueService.isInitialized) {
    await KuchniaQueueService.instance.recordFetched(day);
  }
  return result;
}

/// Drives one screen's "Fill all" button through fetch, confirm and log.
class FillAllFlow {
  /// Creates a flow; every dependency is injectable for tests.
  FillAllFlow({
    DeliveryFetch? fetch,
    DateTime Function()? now,
    List<int> Function(DateTime day)? slots,
    Future<Set<int>> Function(DateTime day)? occupiedSlots,
    LogStorageService? storage,
  }) : _fetch = fetch ?? fetchAndRecord,
       _now = now ?? DateTime.now,
       _slots =
           slots ??
           ((day) =>
               daySlots(MealScheduleService.history.forDay(localDateKey(day)))),
       _occupied =
           occupiedSlots ??
           ((day) => loggedSlotsOn(storage ?? LogStorageService.instance, day)),
       _storage = storage;

  final DeliveryFetch _fetch;
  final DateTime Function() _now;
  final List<int> Function(DateTime day) _slots;
  final Future<Set<int>> Function(DateTime day) _occupied;
  final LogStorageService? _storage;

  List<SlottedDish> _plan = const [];
  DateTime? _planDay;

  /// True while a fetch or a confirm's writes are in flight. A tap meanwhile
  /// is ignored, so a double tap can neither log in twice nor write twice.
  bool busy = false;

  /// How many dishes the armed proposal would log; 0 when nothing is armed.
  int get armedCount => _plan.length;

  DateTime _today() {
    final now = _now();
    return DateTime(now.year, now.month, now.day);
  }

  /// First tap fetches and proposes; a second tap on the same day confirms.
  ///
  /// [day] is the "Log for later" date when one is picked; null means today.
  ///
  /// Returns null when the tap was ignored because one is already in flight,
  /// or when [cancel] ran while its fetch was.
  Future<FillOutcome?> tap({DateTime? day}) async {
    if (busy) return null;
    final target = day == null
        ? _today()
        : DateTime(day.year, day.month, day.day);
    if (_plan.isNotEmpty && _planDay == target) return await _confirm();
    // No plan, one for another picked day, or one proposed before midnight:
    // fetch (again). The day is pinned here, not when the result lands, so a
    // fetch still in flight at midnight can never confirm yesterday's menu
    // into today.
    cancel();
    _planDay = target;
    busy = true;
    try {
      return await _propose(target);
    } finally {
      busy = false;
    }
  }

  Future<FillOutcome?> _propose(DateTime day) async {
    final result = await _fetch(day);
    // Cancelled while the fetch was in flight: arming now would show
    // "Confirm (N)" for a plan the user already dismissed.
    if (_planDay != day) return null;
    if (!result.ok) return (message: result.reason!, written: _none);
    if (result.dishes.isEmpty) {
      final when = day == _today() ? 'today' : 'on ${localDateKey(day)}';
      return (message: 'No catering delivery $when.', written: _none);
    }
    final plan = fillPlan(
      assignSlots(result.dishes, _slots(day)),
      await _occupied(day),
    );
    if (plan.isEmpty) return (message: nothingToFillMessage, written: _none);
    _plan = plan;
    return (message: planSummary(plan), written: _none);
  }

  Future<FillOutcome> _confirm() async {
    busy = true;
    try {
      // Re-checked at write time: a meal logged in between the two taps --
      // here or synced from the PC -- has taken its slot and keeps it.
      final day = _planDay!;
      final plan = fillPlan(_plan, await _occupied(day));
      cancel();
      if (plan.isEmpty) {
        return (message: nothingToFillMessage, written: _none);
      }
      // A later day's dishes are stamped at their slot times on that day;
      // today's at now, like any manual log.
      final later = day == _today() ? null : day;
      final written = await logDishes(plan, storage: _storage, day: later);
      final noun = written.length == 1 ? 'dish' : 'dishes';
      final suffix = later == null ? '' : ' for ${localDateKey(later)}';
      return (
        message: 'Logged ${written.length} catering $noun$suffix.',
        written: written,
      );
    } finally {
      busy = false;
    }
  }

  /// Forgets any proposal, restoring the button's resting label.
  void cancel() {
    _plan = const [];
    _planDay = null;
  }
}
