"""Assign catering dishes to meal slots, in the provider's own order.

The panel returns each dish with a ``mealPriority`` (1..N: Śniadanie, II
śniadanie, Obiad, Podwieczorek, Kolacja) -- the order the catering intends them
to be eaten in.  That beats inferring an order from the dish names, and it
beats spreading them arithmetically, so this module sorts by priority and then
maps position onto the user's configured slots.

Counts rarely match: a 5-meal plan against the default 4 slots means two dishes
share the first slot.  The mapping is ``i * S // N``, which is monotonic
non-decreasing, keeps the first dish on the first slot and the last on the
last, and doubles up the earliest slots rather than dropping anything.

Integer ``//`` only, never ``round()``.  That is repo convention for slot
arithmetic (``docs/meal-schedule.md``): Python's banker's rounding and Dart's
half-away-from-zero disagree on ``.5``, and a slot one device offers while the
other does not is a checkpoint that can never be satisfied.  The parity risk is
theoretical *here* -- the phone has no importer and so no mirror of this code
(see the plan's §8) -- but the rule is cheap to keep and expensive to
rediscover.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, NamedTuple

from diet_guard._meal_schedule_store import current_schedule
from diet_guard._slots import day_slots

if TYPE_CHECKING:
    from collections.abc import Sequence

    from diet_guard._kuchnia_parse import Dish


class SlottedDish(NamedTuple):
    """A dish paired with the meal-slot hour it was assigned to."""

    dish: Dish
    slot: int


def assign_slots(dishes: Sequence[Dish], slots: Sequence[int]) -> list[SlottedDish]:
    """Pair each dish with a slot hour, following the provider's meal order.

    Args:
        dishes: The day's dishes, in any order (sorted here by ``priority``).
        slots: The configured slot hours, ascending, e.g. ``(8, 12, 16, 20)``.

    Returns:
        One :class:`SlottedDish` per dish, ordered by the provider's priority.
        Empty when either input is empty -- a day with no delivery and a
        schedule with no slots are both "nothing to assign", not errors.
    """
    if not dishes or not slots:
        return []
    # Ties (two dishes sharing a priority) fall back to name so the result is
    # deterministic; a bank import that reshuffles between runs would look like
    # a change and re-stamp every record.
    ordered = sorted(dishes, key=lambda dish: (dish.priority, dish.name))
    count = len(ordered)
    span = len(slots)
    return [
        SlottedDish(dish=dish, slot=slots[index * span // count])
        for index, dish in enumerate(ordered)
    ]


def dishes_in_slot_order(dishes: tuple[Dish, ...]) -> tuple[Dish, ...]:
    """Return ``dishes`` ordered by the provider's own meal priority.

    So the dish offered for the slot being filled is the one the catering
    actually intends for it, rather than whatever order the payload arrived in.
    """
    slotted = assign_slots(dishes, day_slots(current_schedule()))
    return tuple(item.dish for item in slotted)


def dish_field_values(dish: Dish) -> tuple[str, tuple[str, ...]]:
    """Return ``(portion_grams, (kcal, protein, carbs, fat))`` as form strings.

    Formatted here rather than in the widget code so the numeric formatting is
    covered by a test that needs no display.
    """
    macros = (dish.kcal, dish.protein_g, dish.carbs_g, dish.fat_g)
    return f"{dish.grams:g}", tuple(f"{value:g}" for value in macros)
