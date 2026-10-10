/// The user's eating window and meal count, and the slot minutes they imply.
///
/// A schedule is three numbers -- the first meal's minute of day, the last
/// meal's minute of day, and how many meals fall between them inclusive --
/// from which the intermediate checkpoints are derived by even division and
/// rounded to the 15-minute grid. `MealSchedule(firstMinute: 480,
/// lastMinute: 1200, count: 5)` yields `[480, 660, 840, 1020, 1200]`.
///
/// Every time here is a *minute of day*, an int in `0..1439`. The fields are
/// deliberately named `firstMinute`/`lastMinute` rather than reusing the old
/// hour-valued `first`/`last`, so `flutter analyze` enumerates every call site
/// that still thinks in hours.
///
/// This file is pure: no clock, no storage, no settings lookup. Persistence
/// lives in `services/meal_schedule_service.dart`, and the slot arithmetic
/// that consumes a schedule lives in `models/slot.dart`.
///
/// KEEP IN SYNC WITH `diet_guard/_meal_schedule.py`. The two must agree on
/// every input, because a device that derives different slots than its peer
/// nags for checkpoints the other never offers -- and a slot that can never be
/// satisfied is a permanent lock. `tests/fixtures/meal_schedule_vectors.json`
/// is read by both test suites; three rules make that agreement checkable:
///
/// * **Integer arithmetic only.** No doubles and no `round()` anywhere in the
///   derivation. Dart's `round()` is half-away-from-zero (`2.5.round() == 3`)
///   while Python's is banker's rounding (`round(2.5) == 2`), so any
///   floating-point path is a latent cross-language split brain. `~/` here,
///   `//` there.
/// * **Non-negative operands to every division.** `~/` truncates while
///   Python's `//` floors (`-7 ~/ 15 == 0`, `-7 // 15 == -1`). Every division
///   below runs on a value [MealSchedule.normalized] has pulled into the day.
/// * **Clamp, don't reject.** Every out-of-range input is normalised to the
///   nearest legal schedule rather than throwing, so the two languages cannot
///   disagree about which inputs are errors.
library;

import 'package:flutter/foundation.dart';

/// Fewest meals a schedule may describe.
const int kMinMealCount = 2;

/// Most meals a schedule may describe.
///
/// Bounded by legibility, not nutrition: the pills that render these have to
/// stay readable on a phone at their widest (all-logged) size -- see
/// `test/widgets/slot_selector_row_test.dart`.
const int kMaxMealCount = 6;

/// Minutes in a day; a minute of day is `0..kMinutesPerDay - 1`.
const int kMinutesPerDay = 1440;

/// Minimum spacing between two checkpoints, and the grid interior checkpoints
/// are rounded onto.
///
/// One constant for both is what makes the strict-ascent proof in
/// [MealSchedule.slots] work: points at least one grid step apart cannot round
/// onto the same grid mark.
const int kSlotGridMinutes = 15;

/// Grace period after the final checkpoint, before the gate stops firing.
///
/// Deliberately a constant rather than the slot spacing: it is how long you
/// have to log a late dinner, which has nothing to do with how many meals you
/// eat. Tying it to the spacing would stretch the lockout window to midnight
/// at four meals, contradicting the "don't trap me overnight" intent.
const int kEnforcementTailMinutes = 120;

const int _lastMinute = kMinutesPerDay - 1;

int _clamp(int value, int low, int high) =>
    value < low ? low : (value > high ? high : value);

/// An eating window and the number of meals inside it.
@immutable
class MealSchedule {
  /// Creates a [MealSchedule].
  const MealSchedule({
    required this.firstMinute,
    required this.lastMinute,
    required this.count,
  });

  /// Minute of day of the first meal, 0-1424.
  final int firstMinute;

  /// Minute of day of the last meal, at least one grid step (15 minutes) after
  /// [firstMinute] and at most 1439.
  final int lastMinute;

  /// Total meals including both endpoints.
  final int count;

  /// Returns an equivalent schedule guaranteed to satisfy the invariants.
  ///
  /// Ordering matters: [firstMinute] is clamped into the day leaving room for
  /// one grid step, then [lastMinute] is clamped to at least one grid step
  /// after it, then [count] is clamped to how many grid-spaced checkpoints the
  /// window holds. That last clamp is the load-bearing one -- see [slots].
  MealSchedule normalized() {
    final first = _clamp(firstMinute, 0, _lastMinute - kSlotGridMinutes);
    final last = _clamp(lastMinute, first + kSlotGridMinutes, _lastMinute);
    // A window of W minutes holds at most W ~/ 15 + 1 checkpoints spaced a
    // grid step apart; asking for more would round two onto one mark.
    final capacity = (last - first) ~/ kSlotGridMinutes + 1;
    final normCount = _clamp(
      count,
      kMinMealCount,
      kMaxMealCount < capacity ? kMaxMealCount : capacity,
    );
    return MealSchedule(firstMinute: first, lastMinute: last, count: normCount);
  }

  /// Returns the meal-slot minutes, ascending, with both endpoints exact.
  ///
  /// With `span = last - first` and `d = count - 1`, interior slot *i* is
  /// `raw = first + (i*span + d ~/ 2) ~/ d` (even division, the `d ~/ 2` term
  /// a round-half-up bias that keeps it free of floating point), then snapped
  /// to the nearest absolute quarter hour by `(raw + 7) ~/ 15 * 15`. The
  /// endpoints are [firstMinute] and [lastMinute] exactly -- never snapped.
  ///
  /// Strictly ascending, provably: [normalized] caps [count] so that
  /// `span / d >= 15`, hence consecutive `raw` values differ by at least 15,
  /// and two integers at least 15 apart never snap onto the same grid mark.
  /// Snapping moves a value by at most 7, so no interior slot can reach an
  /// endpoint. That matters because slot minutes are set members, map keys
  /// *and* notification ids: a repeat silently drops a checkpoint.
  List<int> slots() {
    final schedule = normalized();
    final first = schedule.firstMinute;
    final last = schedule.lastMinute;
    final span = last - first;
    final divisions = schedule.count - 1;
    return [
      first,
      for (var index = 1; index < divisions; index++)
        (first + (index * span + divisions ~/ 2) ~/ divisions + 7) ~/
            kSlotGridMinutes *
            kSlotGridMinutes,
      last,
    ];
  }

  /// The minute at which slot enforcement stops for the day.
  ///
  /// Derived from the *normalised* last meal, so it always agrees with the
  /// last entry of [slots]. Clamped to the end of the day: a 23:00 last meal
  /// would otherwise put the cutoff at 1500, making `minute < cutoff`
  /// vacuously true so the enforcement window never closes.
  int get enforcementEndMinute {
    final end = normalized().lastMinute + kEnforcementTailMinutes;
    return end < kMinutesPerDay ? end : kMinutesPerDay;
  }

  @override
  bool operator ==(Object other) =>
      other is MealSchedule &&
      other.firstMinute == firstMinute &&
      other.lastMinute == lastMinute &&
      other.count == count;

  @override
  int get hashCode => Object.hash(firstMinute, lastMinute, count);

  @override
  String toString() => 'MealSchedule($firstMinute-$lastMinute x$count)';
}

/// The historical hardcoded schedule: 08:00, 12:00, 16:00, 20:00, enforcement
/// closing at 22:00. Still what a device uses before the user has chosen
/// anything, so upgrading changes no behaviour.
const MealSchedule kDefaultSchedule = MealSchedule(
  firstMinute: 8 * 60,
  lastMinute: 20 * 60,
  count: 4,
);

/// Returns the synced `sched:<date>` value for [schedule].
///
/// Mirrors `_meal_schedule.schedule_to_wire`. Backward compatible by
/// construction: `f`/`l` carry whole hours exactly as before the move to
/// minutes, and `fm`/`lm` appear only when an endpoint is off the hour, so a
/// whole-hour schedule encodes byte-identically to the old `{f, l, n}` form.
/// Normalised first, so every `~/` runs on a non-negative value.
Map<String, int> scheduleToWire(MealSchedule schedule) {
  final norm = schedule.normalized();
  final first = norm.firstMinute;
  final last = norm.lastMinute;
  return {
    'f': first ~/ 60,
    'l': last ~/ 60,
    'n': norm.count,
    if (first % 60 != 0) 'fm': first,
    if (last % 60 != 0) 'lm': last,
  };
}

/// Returns the normalised schedule a `sched:<date>` value describes, or null.
///
/// Mirrors `_meal_schedule.schedule_from_wire`. `fm`/`lm` win when they are
/// ints; otherwise `f`/`l` are hours. Never throws: anything without int `f`,
/// `l` and `n` yields null, so one bad field from a peer cannot take out the
/// whole history.
MealSchedule? scheduleFromWire(Object? raw) {
  if (raw is! Map) return null;
  final first = raw['f'];
  final last = raw['l'];
  final count = raw['n'];
  if (first is! int || last is! int || count is! int) return null;
  final firstMinute = raw['fm'];
  final lastMinute = raw['lm'];
  return MealSchedule(
    firstMinute: firstMinute is int ? firstMinute : first * 60,
    lastMinute: lastMinute is int ? lastMinute : last * 60,
    count: count,
  ).normalized();
}
