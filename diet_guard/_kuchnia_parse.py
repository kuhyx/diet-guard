"""Turn the panel's menu payload into ``Dish`` records.

Written against a real capture (``scripts/probe_kuchnia.py``), not against the
field names guessed from the site's JavaScript.  The shape that matters:

    {"deliveryMenuMeal": [
        {"mealName": "Śniadanie",              # the slot label
         "menuMealName": "Marchewkowe pancakes, ...",   # the actual dish
         "mealPriority": 1,                    # eating order, 1..N
         "nutrition": {"weight": 270.0, "calories": 435.0, "protein": 25.86,
                       "carbohydrate": 54.64, "fat": 12.01, ...}},
        ...]}

**Macros are per portion and ``weight`` is that portion in grams.**  Verified
arithmetically rather than assumed: 4·protein + 4·carbs + 9·fat reproduces the
stated ``calories`` within ~1% on every meal of the captured day, and the day
sums to 2055 kcal against the plan's declared 2000.  Had they been per-100 g,
every imported meal would have been silently wrong by a factor of several --
which is why :func:`parse_menu` drops a dish whose numbers do not hold together
instead of importing a plausible-looking lie.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from diet_guard._coerce import as_float

#: Atwater factors. Used only as a sanity check on the *units*, never to
#: recompute a value the panel already states.
_KCAL_PER_G_PROTEIN = 4.0
_KCAL_PER_G_CARB = 4.0
_KCAL_PER_G_FAT = 9.0

#: How far the macro-derived energy may drift from the stated calories before
#: the dish is treated as unusable. Generous: the panel rounds, and fibre and
#: polyols carry energy these three factors ignore. A per-100 g mix-up would
#: miss by a factor of 2-5, nowhere near this band.
_ENERGY_TOLERANCE = 0.35

#: A portion outside this range is not a meal. Guards against a unit change
#: (kg for g) rather than against unusual food.
_MIN_GRAMS = 1.0
_MAX_GRAMS = 5000.0


@dataclass(frozen=True)
class Dish:
    """One delivered dish, with its portion macros.

    Mirrors :class:`diet_guard._estimator.Nutrition`'s convention: every macro
    is the total *for this portion*, not per 100 g.
    """

    name: str
    kcal: float
    protein_g: float
    carbs_g: float
    fat_g: float
    grams: float
    priority: int
    slot_label: str


def _energy_is_consistent(
    kcal: float, protein: float, carbs: float, fat: float
) -> bool:
    """Return True when the macros roughly account for the stated calories.

    This is a *unit* check, not a nutrition check: it catches a payload whose
    macros and calories are quoted on different bases (per portion vs per
    100 g), which is the one failure mode that would corrupt every import
    without looking wrong.
    """
    if kcal <= 0:
        return False
    derived = (
        _KCAL_PER_G_PROTEIN * protein + _KCAL_PER_G_CARB * carbs + _KCAL_PER_G_FAT * fat
    )
    return abs(derived - kcal) <= _ENERGY_TOLERANCE * kcal


def _parse_meal(meal: object, fallback_priority: int) -> Dish | None:
    """Build one :class:`Dish`, or None when the entry is unusable.

    Args:
        meal: One ``deliveryMenuMeal`` element.
        fallback_priority: Position to use when ``mealPriority`` is missing.

    Returns:
        The dish, or None when it lacks a name or fails the unit check.
    """
    if not isinstance(meal, dict):
        return None
    nutrition = meal.get("nutrition")
    if not isinstance(nutrition, dict):
        return None

    # ``menuMealName`` is the dish ("Kaszotto grzybowe..."); ``mealName`` is the
    # slot label ("Kolacja"). The dish is what belongs in the food bank -- the
    # label would collapse every Monday dinner onto one bank entry.
    name = str(meal.get("menuMealName") or "").strip()
    if not name:
        return None

    kcal = as_float(nutrition.get("calories"))
    protein = as_float(nutrition.get("protein"))
    carbs = as_float(nutrition.get("carbohydrate"))
    fat = as_float(nutrition.get("fat"))
    grams = as_float(nutrition.get("weight"))

    if not _MIN_GRAMS <= grams <= _MAX_GRAMS:
        return None
    if not _energy_is_consistent(kcal, protein, carbs, fat):
        return None

    raw_priority = meal.get("mealPriority")
    priority = (
        raw_priority
        if isinstance(raw_priority, int) and not isinstance(raw_priority, bool)
        else fallback_priority
    )
    return Dish(
        name=name,
        kcal=kcal,
        protein_g=protein,
        carbs_g=carbs,
        fat_g=fat,
        grams=grams,
        priority=priority,
        slot_label=str(meal.get("mealName") or "").strip(),
    )


def parse_menu(payload: object) -> list[Dish]:
    """Extract the day's dishes from a ``menus/delivery/{id}/new`` response.

    Unusable entries are skipped rather than raising: a single malformed dish
    must not cost the user the other four.

    Args:
        payload: The decoded response body.

    Returns:
        The dishes, in payload order (:mod:`diet_guard._kuchnia_spread` sorts
        them by priority).
    """
    if not isinstance(payload, dict):
        return []
    meals: Any = payload.get("deliveryMenuMeal")
    if not isinstance(meals, list):
        return []
    parsed = (_parse_meal(meal, index + 1) for index, meal in enumerate(meals))
    return [dish for dish in parsed if dish is not None]
