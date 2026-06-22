"""Composite "meal" support for diet_guard.

A meal is a named group of individually-macroed items -- e.g. a dinner of
salad + chicken + rice, each entered with its own calories and macros.  The
meal's nutrition is the sum of its items.  Both the individual items and the
composite meal are saved to the food bank (see
:func:`diet_guard._foodbank.remember_meal`), so next time each item
autocompletes on its own and the whole meal can be picked as one summed entry.

This module is deliberately pure (no I/O): the sum is a total function of its
items, which keeps the arithmetic exhaustively unit-testable apart from the
bank persistence and the gate UI that compose it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from diet_guard._estimator import Nutrition

if TYPE_CHECKING:
    from collections.abc import Sequence

# Provenance stamped on a summed meal so the log/UI can tell a composite apart
# from a single looked-up food.
MEAL_SOURCE = "meal"


@dataclass(frozen=True)
class MealItem:
    """One named component of a composite meal, with its own nutrition.

    Attributes:
        name: The component's food name (e.g. ``"chicken"``).
        nutrition: The component's resolved macros for the amount eaten.
    """

    name: str
    nutrition: Nutrition


def meal_total(items: Sequence[MealItem]) -> Nutrition:
    """Return the summed nutrition of a meal's items.

    Every macro and the portion weight are added across the items and rounded to
    0.1, and the result is stamped ``source=MEAL_SOURCE`` so it is
    distinguishable from a single food.  An empty sequence sums to an all-zero
    meal rather than raising, so callers need not special-case "no items yet".

    Args:
        items: The meal's components.

    Returns:
        A :class:`~diet_guard._estimator.Nutrition` whose fields are
        the per-item sums.
    """
    return Nutrition(
        kcal=round(sum((item.nutrition.kcal for item in items), 0.0), 1),
        protein_g=round(sum((item.nutrition.protein_g for item in items), 0.0), 1),
        carbs_g=round(sum((item.nutrition.carbs_g for item in items), 0.0), 1),
        fat_g=round(sum((item.nutrition.fat_g for item in items), 0.0), 1),
        grams=round(sum((item.nutrition.grams for item in items), 0.0), 1),
        source=MEAL_SOURCE,
    )


def item_to_component(item: MealItem) -> dict[str, object]:
    """Return a composite meal's per-component log record for ``item``.

    The food bank's own ``components`` field (see
    :func:`diet_guard._foodbank.remember_meal`) stores only component
    *names* -- it is rebuilt from the log, not the other way round. This
    record carries the component's full macros so a bank rebuilt purely by
    replaying the log (the companion phone app's sync model) can recover
    each component's standalone nutrition, not just the composite's summed
    total.

    Args:
        item: One component of a composite meal.

    Returns:
        A plain dict of the component's name and macros, suitable for the
        ``components`` list passed to :func:`diet_guard._state.log_meal`.
    """
    return {
        "name": item.name,
        "kcal": item.nutrition.kcal,
        "protein_g": item.nutrition.protein_g,
        "carbs_g": item.nutrition.carbs_g,
        "fat_g": item.nutrition.fat_g,
        "grams": item.nutrition.grams,
    }
