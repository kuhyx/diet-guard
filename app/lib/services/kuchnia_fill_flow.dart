/// The two-tap state machine behind "Fill all with catering".
///
/// Mirrors `diet_guard/_gatelock_fillall.py`'s `FillAllFlow`. Two taps, never
/// one: the first fetches today's delivery and proposes exactly what would be
/// written; only the second writes. No modal dialog -- the proposal is a
/// status line and the button relabels to "✓ Confirm (N)".
///
/// Widget-free so the flow's guarantees (first tap writes nothing, confirm
/// re-checks occupancy, a plan from before midnight refetches) are testable
/// with an injected clock and fetch.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/kuchnia_fill.dart';
import 'package:diet_guard_app/services/kuchnia_import.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';

/// Fetches one day's delivery.
typedef DeliveryFetch = Future<KuchniaRefresh> Function(DateTime day);

/// What one tap produced: a line for the user, and what (if anything) landed.
typedef FillOutcome = ({String message, List<SlottedDish> written});

/// The empty "nothing written" half of a [FillOutcome].
const _none = <SlottedDish>[];

/// The status line when every slot the delivery covers already holds a meal.
const nothingToFillMessage = 'Every slot already has a meal — nothing to fill.';

/// The explicit tap's fetch: unguarded, like "Today's delivery", and it
/// records the fetch so the automatic path is spared a second walk.
Future<KuchniaRefresh> _fetchAndRecord(DateTime day) async {
  final result = await refreshDelivery(day);
  if (result.ok &&
      result.dishes.isNotEmpty &&
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
    List<int> Function()? slots,
    Future<Set<int>> Function()? occupiedSlots,
    LogStorageService? storage,
  }) : _fetch = fetch ?? _fetchAndRecord,
       _now = now ?? DateTime.now,
       _slots = slots ?? (() => daySlots(MealScheduleService.current)),
       _occupied =
           occupiedSlots ??
           (() => (storage ?? LogStorageService.instance).loggedSlotsToday()),
       _storage = storage;

  final DeliveryFetch _fetch;
  final DateTime Function() _now;
  final List<int> Function() _slots;
  final Future<Set<int>> Function() _occupied;
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
  /// Returns null when the tap was ignored because one is already in flight,
  /// or when [cancel] ran while its fetch was.
  Future<FillOutcome?> tap() async {
    if (busy) return null;
    final today = _today();
    if (_plan.isNotEmpty && _planDay == today) return await _confirm();
    // No plan, or one proposed before midnight: fetch (again). The day is
    // pinned here, not when the result lands, so a fetch still in flight at
    // midnight can never confirm yesterday's menu into today.
    cancel();
    _planDay = today;
    busy = true;
    try {
      return await _propose(today);
    } finally {
      busy = false;
    }
  }

  Future<FillOutcome?> _propose(DateTime today) async {
    final result = await _fetch(today);
    // Cancelled while the fetch was in flight: arming now would show
    // "Confirm (N)" for a plan the user already dismissed.
    if (_planDay != today) return null;
    if (!result.ok) return (message: result.reason!, written: _none);
    if (result.dishes.isEmpty) {
      return (message: 'No catering delivery today.', written: _none);
    }
    final plan = fillPlan(
      assignSlots(result.dishes, _slots()),
      await _occupied(),
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
      final plan = fillPlan(_plan, await _occupied());
      cancel();
      if (plan.isEmpty) {
        return (message: nothingToFillMessage, written: _none);
      }
      final written = await logDishes(plan, storage: _storage);
      final noun = written.length == 1 ? 'dish' : 'dishes';
      return (
        message: 'Logged ${written.length} catering $noun.',
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
