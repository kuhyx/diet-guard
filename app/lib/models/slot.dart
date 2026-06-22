/// Pure meal-slot arithmetic, mirroring diet_guard's `_slots.py`.
///
/// Deliberately I/O-free and clock-free: every function is a total function
/// of its `now` argument and the fixed slot constants below, so the
/// time-of-day edges are exhaustively unit-testable without mocking the
/// wall clock. Shared between the in-app status bar and the background
/// notification check (Milestone 4), exactly like the Python original is
/// shared between the gate dashboard and the lock decision.
library;

/// First slot hour of the day (08:00), mirrors `GATE_DAY_START_HOUR`.
const int gateDayStartHour = 8;

/// Hours between slots, mirrors `GATE_SLOT_INTERVAL_HOURS`.
const int gateSlotIntervalHours = 4;

/// Exclusive end of the enforcement window (22:00), mirrors
/// `GATE_EATING_END_HOUR`.
const int gateEatingEndHour = 22;

/// Returns the fixed meal-slot hours for a day, e.g. `(8, 12, 16, 20)`.
///
/// Mirrors `_slots.day_slots`.
List<int> daySlots() {
  final slots = <int>[];
  for (var hour = gateDayStartHour; hour < gateEatingEndHour;
      hour += gateSlotIntervalHours) {
    slots.add(hour);
  }
  return slots;
}

/// Returns true if [now] is inside the daily slot-enforcement window.
///
/// Mirrors `_slots.within_enforcement_window`.
bool withinEnforcementWindow(DateTime now) =>
    now.hour >= gateDayStartHour && now.hour < gateEatingEndHour;

/// Returns today's slots whose hour has arrived as of [now].
///
/// Empty outside the enforcement window. Mirrors `_slots.elapsed_slots`.
List<int> elapsedSlots(DateTime now) {
  if (!withinEnforcementWindow(now)) return const [];
  return daySlots().where((slot) => slot <= now.hour).toList();
}

/// Returns elapsed slots not yet covered by [logged].
///
/// Mirrors `_slots.missing_slots`.
List<int> missingSlots(DateTime now, Set<int> logged) =>
    elapsedSlots(now).where((slot) => !logged.contains(slot)).toList();

/// Returns the most recent elapsed slot as of [now], or null.
///
/// Mirrors `_slots.current_slot`.
int? currentSlot(DateTime now) {
  final elapsed = elapsedSlots(now);
  return elapsed.isEmpty ? null : elapsed.last;
}

/// Returns a human `HH:00` label for [slot], e.g. `"08:00"`.
///
/// Mirrors `_slots.slot_label`.
String slotLabel(int slot) => '${(slot % 24).toString().padLeft(2, '0')}:00';
