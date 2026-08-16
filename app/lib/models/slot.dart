/// Pure meal-slot arithmetic, mirroring diet_guard's `_slots.py`.
///
/// Deliberately I/O-free and clock-free: every function is a total function of
/// its `now` and `schedule` arguments, so the time-of-day edges are
/// exhaustively unit-testable without mocking the wall clock. Shared between
/// the in-app status row and the background notification check, exactly like
/// the Python original is shared between the gate dashboard and the lock
/// decision.
///
/// `schedule` is a required argument on every function here, deliberately: it
/// used to be read from module constants, and a default would let a call site
/// that was missed during a refactor keep deriving the old fixed hours on one
/// device only. That is the split brain this design exists to prevent -- a
/// slot one device offers and the other does not is a checkpoint that can
/// never be satisfied. Callers resolve the value at the impure edge, through
/// `MealScheduleService.current`.
library;

import 'package:diet_guard_app/models/meal_schedule.dart';

/// Returns the meal-slot hours for a day, e.g. `[8, 12, 16, 20]`.
///
/// Mirrors `_slots.day_slots`.
List<int> daySlots(MealSchedule schedule) => schedule.slots();

/// Returns true if [now] is inside the daily slot-enforcement window.
///
/// Mirrors `_slots.within_enforcement_window`.
bool withinEnforcementWindow(DateTime now, MealSchedule schedule) =>
    now.hour >= schedule.slots().first &&
    now.hour < schedule.enforcementEndHour;

/// Returns today's slots whose hour has arrived as of [now].
///
/// Empty outside the enforcement window. Mirrors `_slots.elapsed_slots`.
List<int> elapsedSlots(DateTime now, MealSchedule schedule) {
  if (!withinEnforcementWindow(now, schedule)) return const [];
  return daySlots(schedule).where((slot) => slot <= now.hour).toList();
}

/// Returns elapsed slots not yet covered by [logged].
///
/// Mirrors `_slots.missing_slots`.
List<int> missingSlots(
  DateTime now,
  Set<int> logged,
  MealSchedule schedule,
) => elapsedSlots(
  now,
  schedule,
).where((slot) => !logged.contains(slot)).toList();

/// Returns the most recent elapsed slot as of [now], or null.
///
/// Mirrors `_slots.current_slot`.
int? currentSlot(DateTime now, MealSchedule schedule) {
  final elapsed = elapsedSlots(now, schedule);
  return elapsed.isEmpty ? null : elapsed.last;
}

/// Returns the slot a meal logged at [now] should be attributed to.
///
/// CLAMP RULE (keep byte-identical with `_slots.slot_for_log`): before the
/// first slot, clamp to the first slot; after the enforcement window ends,
/// clamp to the last slot; behaviour inside a window is unchanged. The two
/// languages must reach each answer by the *same* branch, not merely agree on
/// the value -- `test/models/slot_test.dart` sweeps every hour of the day
/// against several schedules for exactly that reason.
///
/// Unlike [currentSlot] this never returns null, which is the point: an
/// off-hours meal used to satisfy no slot at all, so eating at 07:30 or 22:30
/// still produced a "you haven't logged your meal" reminder. Attribution is
/// deliberately separate from [elapsedSlots]/[missingSlots] -- widening
/// *those* would instead make every slot fall due at the end of the day.
int slotForLog(DateTime now, MealSchedule schedule) {
  final slots = daySlots(schedule);
  if (now.hour < slots.first) return slots.first;
  return currentSlot(now, schedule) ?? slots.last;
}

/// Returns a human `HH:00` label for [slot], e.g. `"08:00"`.
///
/// Mirrors `_slots.slot_label`.
String slotLabel(int slot) => '${(slot % 24).toString().padLeft(2, '0')}:00';
