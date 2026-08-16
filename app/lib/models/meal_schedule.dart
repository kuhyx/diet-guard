/// The user's eating window and meal count, and the slot hours they imply.
///
/// A schedule is three numbers -- the first meal hour, the last meal hour, and
/// how many meals fall between them inclusive -- from which the intermediate
/// checkpoints are derived by even division. `MealSchedule(8, 20, 5)` yields
/// `[8, 11, 14, 17, 20]`.
///
/// This file is pure: no clock, no storage, no settings lookup. Persistence
/// lives in `services/meal_schedule_service.dart`, and the slot arithmetic
/// that consumes a schedule lives in `models/slot.dart`.
///
/// KEEP IN SYNC WITH `diet_guard/_meal_schedule.py`. The two must agree on
/// every input, because a device that derives different slots than its peer
/// nags for checkpoints the other never offers -- and a slot that can never be
/// satisfied is a permanent lock. Two rules make that agreement checkable:
///
/// * **Integer arithmetic only.** No doubles and no `round()` anywhere in the
///   derivation. Dart's `round()` is half-away-from-zero (`2.5.round() == 3`)
///   while Python's is banker's rounding (`round(2.5) == 2`), so any
///   floating-point path is a latent cross-language split brain. `~/` here,
///   `//` there.
/// * **Clamp, don't reject.** Every out-of-range input is normalised to the
///   nearest legal schedule rather than throwing, so the two languages cannot
///   disagree about which inputs are errors.
library;

import 'package:meta/meta.dart';

/// Fewest meals a schedule may describe.
const int kMinMealCount = 2;

/// Most meals a schedule may describe.
///
/// Bounded by legibility, not nutrition: the pills that render these have to
/// stay readable on a phone at their widest (all-logged) size -- see
/// `test/widgets/slot_selector_row_test.dart`.
const int kMaxMealCount = 6;

/// Earliest hour a meal may be scheduled at.
const int kFirstHour = 0;

/// Latest hour a meal may be scheduled at.
const int kLastHour = 23;

/// Grace period after the final checkpoint, before the gate stops firing.
///
/// Deliberately a constant rather than the slot spacing: it is how long you
/// have to log a late dinner, which has nothing to do with how many meals you
/// eat. Tying it to the spacing would stretch the lockout window to midnight
/// at four meals, contradicting the "don't trap me overnight" intent.
const int kEnforcementTailHours = 2;

const int _hoursPerDay = 24;

int _clamp(int value, int low, int high) =>
    value < low ? low : (value > high ? high : value);

/// An eating window and the number of meals inside it.
@immutable
class MealSchedule {
  /// Creates a [MealSchedule].
  const MealSchedule({
    required this.first,
    required this.last,
    required this.count,
  });

  /// Hour of the first meal, 0-23.
  final int first;

  /// Hour of the last meal, strictly after [first].
  final int last;

  /// Total meals including both endpoints.
  final int count;

  /// Returns an equivalent schedule guaranteed to satisfy the invariants.
  ///
  /// Ordering matters: [first] is clamped into the day, then [last] is clamped
  /// to leave at least one hour of window, then [count] is clamped to the
  /// window's width. That last clamp is the load-bearing one -- see [slots].
  MealSchedule normalized() {
    final normFirst = _clamp(first, kFirstHour, kLastHour - 1);
    final normLast = _clamp(last, normFirst + 1, kLastHour);
    // A window of N hours holds at most N+1 whole-hour checkpoints; asking for
    // more would repeat an hour (see slots()).
    final normCount = _clamp(
      count,
      kMinMealCount,
      kMaxMealCount < normLast - normFirst + 1
          ? kMaxMealCount
          : normLast - normFirst + 1,
    );
    return MealSchedule(first: normFirst, last: normLast, count: normCount);
  }

  /// Returns the meal-slot hours, ascending, with both endpoints exact.
  ///
  /// Meals are spread evenly across the window and rounded to whole hours by
  /// integer arithmetic: slot *i* is `first + (i*span + d ~/ 2) ~/ d` where
  /// `span = last - first` and `d = count - 1`. The `d ~/ 2` term is a
  /// round-half-up bias applied before the division, which is what keeps this
  /// free of floating point.
  ///
  /// Both endpoints land exactly on [first] and [last] by construction, so the
  /// eating window is always honoured even when interior spacing must round.
  ///
  /// The result is strictly ascending because [normalized] caps [count] at
  /// `last - first + 1`. Without that cap a narrow window repeats an hour
  /// (`08-12` with 6 meals would give `8, 9, 10, 10, 11, 12`), and since slot
  /// hours are used as set members, map keys *and* notification ids, a repeat
  /// silently drops a checkpoint.
  List<int> slots() {
    final schedule = normalized();
    final span = schedule.last - schedule.first;
    final divisions = schedule.count - 1;
    return [
      for (var index = 0; index < schedule.count; index++)
        schedule.first + (index * span + divisions ~/ 2) ~/ divisions,
    ];
  }

  /// The hour at which slot enforcement stops for the day.
  ///
  /// Clamped to the end of the day: a 23:00 last meal would otherwise put the
  /// cutoff at 25, making `hour < cutoff` vacuously true so the enforcement
  /// window never closes and the reminder can never stop firing.
  int get enforcementEndHour {
    final end = last + kEnforcementTailHours;
    return end < _hoursPerDay ? end : _hoursPerDay;
  }

  @override
  bool operator ==(Object other) =>
      other is MealSchedule &&
      other.first == first &&
      other.last == last &&
      other.count == count;

  @override
  int get hashCode => Object.hash(first, last, count);

  @override
  String toString() => 'MealSchedule($first-$last x$count)';
}

/// The historical hardcoded schedule: 08:00, 12:00, 16:00, 20:00, enforcement
/// closing at 22:00. Still what a device uses before the user has chosen
/// anything, so upgrading changes no behaviour.
const MealSchedule kDefaultSchedule = MealSchedule(
  first: 8,
  last: 20,
  count: 4,
);
