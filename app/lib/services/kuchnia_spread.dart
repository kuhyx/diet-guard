/// Assigns catering dishes to meal slots, in the provider's own order.
///
/// The Dart mirror of `diet_guard/_kuchnia_spread.py`.
///
/// The panel returns each dish with a `mealPriority` (1..N: Śniadanie, II
/// śniadanie, Obiad, Podwieczorek, Kolacja) -- the order the catering intends
/// them to be eaten in. That beats inferring an order from the dish names, and
/// it beats spreading them arithmetically.
///
/// Counts rarely match: a 5-meal plan against the default 4 slots means two
/// dishes share the first slot. The mapping is `i * S ~/ N`, which is
/// monotonic non-decreasing, keeps the first dish on the first slot and the
/// last on the last, and doubles up the earliest slots rather than dropping
/// anything.
///
/// **Integer `~/` only, never `round()`.** Repo convention for slot arithmetic
/// (`docs/meal-schedule.md`): Python's `round` is banker's and Dart's is
/// half-away-from-zero, so a float path silently desyncs the two devices --
/// and a slot one device offers while the other does not is a checkpoint that
/// can never be satisfied, i.e. a permanent lock. `index`, `span` and `count`
/// are all `int`, so `~/` matches Python's `//` exactly (`~/` on doubles
/// truncates toward zero where `//` floors).
///
/// KEEP IN SYNC WITH `diet_guard/_kuchnia_spread.py`, gated by
/// `tests/fixtures/kuchnia_day.json`.
library;

import 'package:diet_guard_app/models/kuchnia_dish.dart';

/// A dish paired with the meal-slot hour it was assigned to.
class SlottedDish {
  /// Pairs [dish] with the [slot] hour it should be logged against.
  const SlottedDish({required this.dish, required this.slot});

  /// The dish itself.
  final KuchniaDish dish;

  /// The slot hour, e.g. `12` for the 12:00 checkpoint.
  final int slot;
}

/// Pairs each dish with a slot hour, following the provider's meal order.
///
/// Returns an empty list when either input is empty -- a day with no delivery
/// and a schedule with no slots are both "nothing to assign", not errors.
List<SlottedDish> assignSlots(List<KuchniaDish> dishes, List<int> slots) {
  if (dishes.isEmpty || slots.isEmpty) return const [];

  // Ties fall back to name so the result is deterministic; a bank import that
  // reshuffled between runs would look like a change and re-stamp every
  // record.
  //
  // The payload index is the final tiebreak because `List.sort` is *not*
  // stable in Dart while Python's `sorted` is: two dishes sharing both
  // priority and name would otherwise be free to swap here and not on the PC.
  // With the index in the comparator the ordering is total, so both languages
  // agree without relying on either sort's stability.
  final indexed = <(int, KuchniaDish)>[
    for (var i = 0; i < dishes.length; i++) (i, dishes[i]),
  ];
  indexed.sort((a, b) {
    final byPriority = a.$2.priority.compareTo(b.$2.priority);
    if (byPriority != 0) return byPriority;
    final byName = a.$2.name.compareTo(b.$2.name);
    if (byName != 0) return byName;
    return a.$1.compareTo(b.$1);
  });

  final count = indexed.length;
  final span = slots.length;
  return [
    for (var index = 0; index < count; index++)
      SlottedDish(
        dish: indexed[index].$2,
        slot: slots[index * span ~/ count],
      ),
  ];
}

/// Returns [dishes] ordered by the provider's own meal priority.
///
/// So the dish offered for the slot being filled is the one the catering
/// actually intends for it, rather than whatever order the payload arrived in.
List<KuchniaDish> dishesInSlotOrder(List<KuchniaDish> dishes, List<int> slots) =>
    [for (final item in assignSlots(dishes, slots)) item.dish];
