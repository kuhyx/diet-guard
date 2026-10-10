/// Pure meal-slot arithmetic, mirroring diet_guard's `_slots.py` and
/// `_slot_wire.py`.
///
/// Deliberately I/O-free and clock-free: every function is a total function of
/// its `now` and `schedule` arguments, so the time-of-day edges are
/// exhaustively unit-testable without mocking the wall clock. Shared between
/// the in-app status row and the background notification check, exactly like
/// the Python original is shared between the gate dashboard and the lock
/// decision.
///
/// A slot is a *minute of day* (`0..1439`): 480, 720, 960, 1200 by default.
/// A logged meal satisfies the slot nearest its recorded slot minute
/// ([satisfiedSlots]), so an entry written under an older schedule still
/// counts after the schedule moves -- nothing stored is ever rewritten.
///
/// `schedule` is a required argument on every function here, deliberately: it
/// used to be read from module constants, and a default would let a call site
/// that was missed during a refactor keep deriving the old fixed hours on one
/// device only. That is the split brain this design exists to prevent -- a
/// slot one device offers and the other does not is a checkpoint that can
/// never be satisfied. Callers resolve the value at the impure edge, through
/// `MealScheduleService.current`.
///
/// **Entry wire rule** (mirrors `_slot_wire.py`): writers always write
/// `slot = minute ~/ 60` and add `slot_min = minute` only when the minute is
/// off the hour, so whole-hour entries stay byte-identical to the pre-minute
/// format and an older peer still reads an hour. Readers prefer an int
/// `slot_min`, then `slot * 60`, else no slot. See [slotFields] and
/// [entrySlotMinute]; `tests/fixtures/meal_schedule_vectors.json` gates both
/// languages.
library;

import 'package:diet_guard_app/models/meal_schedule.dart';

/// Returns [now]'s minute of day, `0..1439` (seconds are ignored).
///
/// Mirrors `_slots.minute_of_day`.
int minuteOfDay(DateTime now) => now.hour * 60 + now.minute;

/// Returns the meal-slot minutes for a day, e.g. `[480, 720, 960, 1200]`.
///
/// Mirrors `_slots.day_slots`.
List<int> daySlots(MealSchedule schedule) => schedule.slots();

/// Returns true if [now] is inside the daily slot-enforcement window.
///
/// Mirrors `_slots.within_enforcement_window`.
bool withinEnforcementWindow(DateTime now, MealSchedule schedule) {
  final minute = minuteOfDay(now);
  return schedule.slots().first <= minute &&
      minute < schedule.enforcementEndMinute;
}

/// Returns today's slots whose minute has arrived as of [now].
///
/// Empty outside the enforcement window. Mirrors `_slots.elapsed_slots`.
List<int> elapsedSlots(DateTime now, MealSchedule schedule) {
  if (!withinEnforcementWindow(now, schedule)) return const [];
  final minute = minuteOfDay(now);
  return daySlots(schedule).where((slot) => slot <= minute).toList();
}

/// Returns elapsed slots not yet covered by [logged] (normally
/// [satisfiedSlots] of the entries' slot minutes).
///
/// Mirrors `_slots.missing_slots`.
List<int> missingSlots(DateTime now, Set<int> logged, MealSchedule schedule) =>
    elapsedSlots(
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
/// the value -- the shared fixture pins every minute edge for that reason.
///
/// Unlike [currentSlot] this never returns null, which is the point: an
/// off-hours meal used to satisfy no slot at all, so eating at 07:30 or 22:30
/// still produced a "you haven't logged your meal" reminder. Attribution is
/// deliberately separate from [elapsedSlots]/[missingSlots] -- widening
/// *those* would instead make every slot fall due at the end of the day.
int slotForLog(DateTime now, MealSchedule schedule) {
  final slots = daySlots(schedule);
  if (minuteOfDay(now) < slots.first) return slots.first;
  return currentSlot(now, schedule) ?? slots.last;
}

/// Returns the slot closest to [minute]; an exact tie goes to the earlier.
///
/// Mirrors `_slots.nearest_slot`, whose `min` keeps the first minimal element
/// of the ascending slots -- hence replacing the best only on a strictly
/// smaller distance here.
int nearestSlot(int minute, MealSchedule schedule) {
  final slots = daySlots(schedule);
  var best = slots.first;
  for (final slot in slots) {
    if ((slot - minute).abs() < (best - minute).abs()) best = slot;
  }
  return best;
}

/// Returns the slots covered by meals recorded at [entryMinutes].
///
/// Mirrors `_slots.satisfied_slots`. Many-to-one is intended: two meals
/// snapping onto one slot satisfy only that slot.
Set<int> satisfiedSlots(Iterable<int> entryMinutes, MealSchedule schedule) => {
  for (final minute in entryMinutes) nearestSlot(minute, schedule),
};

/// Returns the entry fields that record [minute] as its slot.
///
/// Mirrors `_slot_wire.slot_fields`; throws [ArgumentError] for a minute
/// outside the day, as Python raises `ValueError`.
Map<String, int> slotFields(int minute) {
  if (minute < 0 || minute >= kMinutesPerDay) {
    throw ArgumentError.value(
      minute,
      'minute',
      'slot minute is outside 0..${kMinutesPerDay - 1}',
    );
  }
  return {'slot': minute ~/ 60, if (minute % 60 != 0) 'slot_min': minute};
}

/// Returns the slot minute a raw log entry records, or null when it has none.
///
/// Mirrors `_slot_wire.entry_slot_minute`: an int `slot_min` wins, else an int
/// `slot` is an hour, else null. Values are not range-checked.
int? entrySlotMinute(Map<String, Object?> entry) {
  final slotMin = entry['slot_min'];
  if (slotMin is int) return slotMin;
  final slot = entry['slot'];
  if (slot is int) return slot * 60;
  return null;
}

/// Returns a human `HH:MM` label for a slot minute, e.g. `"07:15"`.
///
/// Mirrors `_slots.slot_label`.
String slotLabel(int minute) {
  final wrapped = minute % kMinutesPerDay;
  final hours = (wrapped ~/ 60).toString().padLeft(2, '0');
  final minutes = (wrapped % 60).toString().padLeft(2, '0');
  return '$hours:$minutes';
}
