"""Composite "meal" support for diet_guard.

A meal is a named group of individually-macroed items -- e.g. a dinner of
salad + chicken + rice, each entered with its own calories and macros.  The
meal's nutrition is the sum of its items.  Both the individual items and the
composite meal are saved to the food bank (see
:func:`python_pkg.diet_guard._foodbank.remember_meal`), so next time each item
autocompletes on its own and the whole meal can be picked as one summed entry.

This module is deliberately pure (no I/O): the sum is a total function of its
items, which keeps the arithmetic exhaustively unit-testable apart from the
bank persistence and the gate UI that compose it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from python_pkg.diet_guard._estimator import Nutrition

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
        A :class:`~python_pkg.diet_guard._estimator.Nutrition` whose fields are
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
