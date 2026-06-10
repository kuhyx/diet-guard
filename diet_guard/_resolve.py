"""Resolve a food description to nutrition, food-bank first, OFF last.

This is the shared precedence both the CLI and the gate window use so a food is
always resolved the same way:

1. **Manual calories** the user typed -- always honored, always offline.  Full
   macros are recorded too when supplied.
2. **The food bank** -- a food the user has logged before is served from local
   history with its remembered macros (no network).
3. **Open Food Facts** -- only for a brand-new food with no manual value, to
   fill in macros the first time it is seen.

Keeping Open Food Facts strictly last is what makes the gate offline-safe: a
dead endpoint can never stop you logging a manual or already-known food, so the
lock can never trap you.
"""

from __future__ import annotations

from dataclasses import dataclass

from python_pkg.diet_guard._estimator import (
    Nutrition,
    estimate_off,
    manual,
    off_candidates,
    scale_nutrition,
)
from python_pkg.diet_guard._foodbank import lookup_food, search_foods
from python_pkg.diet_guard._portions import staple_nutrition, suggest_staples


@dataclass(frozen=True)
class ManualMacros:
    """Calories and optional macros the user typed directly for a food.

    Bundling these keeps :func:`resolve_nutrition` to a short argument list.

    Attributes:
        kcal: Calories entered directly; when supplied the lookups are skipped.
        protein: Protein grams to record alongside ``kcal``.
        carbs: Carbohydrate grams to record alongside ``kcal``.
        fat: Fat grams to record alongside ``kcal``.
        per_grams: Reference weight the macros are stated for (e.g. 100 for
            "per 100 g" off a label).  When given, the typed macros are scaled
            from this basis to the eaten amount; when None they are taken as
            totals for the portion (back-compatible behaviour).
    """

    kcal: float
    protein: float = 0.0
    carbs: float = 0.0
    fat: float = 0.0
    per_grams: float | None = None


def resolve_nutrition(
    description: str,
    *,
    grams: float | None = None,
    manual_macros: ManualMacros | None = None,
) -> Nutrition | None:
    """Resolve ``description`` to a :class:`Nutrition`, or None if unresolvable.

    Args:
        description: Free-text food name.
        grams: Amount actually eaten, in grams (used to rescale every source).
        manual_macros: Calories and macros the user typed directly; when given,
            they are recorded and the lookups are skipped entirely.

    Returns:
        The resolved Nutrition, or None only when no manual value was supplied,
        the food is neither banked nor a known staple, and Open Food Facts
        produced no usable match.
    """
    if manual_macros is not None:
        # The typed macros describe ``per_grams`` of food (the label basis);
        # build that reference, then rescale it to the amount actually eaten so
        # "200 kcal per 100 g, ate 330 g" logs 660 -- no manual arithmetic.
        reference_grams = (
            manual_macros.per_grams if manual_macros.per_grams is not None else grams
        )
        reference = manual(
            manual_macros.kcal,
            reference_grams,
            protein_g=manual_macros.protein,
            carbs_g=manual_macros.carbs,
            fat_g=manual_macros.fat,
        )
        eaten = grams if grams is not None else reference_grams
        return scale_nutrition(reference, eaten) if eaten is not None else reference
    banked = lookup_food(description)
    if banked is not None:
        # Reuse the remembered macros, rescaled if a different amount was eaten.
        return scale_nutrition(banked, grams) if grams is not None else banked
    staple = staple_nutrition(description)
    if staple is not None:
        # A known whole food (apple, egg, ...) resolves locally and correctly,
        # before Open Food Facts whose top "apple" hit is a packaged pastry.
        return scale_nutrition(staple, grams) if grams is not None else staple
    return estimate_off(description, grams)


def lookup_candidates(
    description: str,
    grams: float | None = None,
) -> list[tuple[str, Nutrition]]:
    """Return reviewable candidates for a food whose macros must be looked up.

    Used by the gate when the user leaves the calorie field blank: it returns
    the banked food if known (a single, instant, offline match), otherwise the
    Open Food Facts alternatives so the user can pick the right product and see
    where each value comes from.  Empty means nothing resolved -- the caller
    must then ask for a manual calorie value (the offline-safe escape).

    Args:
        description: Free-text food name the user typed.
        grams: Portion size in grams, if the user supplied one.

    Returns:
        ``(label, nutrition)`` pairs to show for review; at most one for a
        banked food, otherwise the OFF candidates in relevance order.
    """
    banked = lookup_food(description)
    if banked is not None:
        scaled = scale_nutrition(banked, grams) if grams is not None else banked
        return [(description, scaled)]
    staple = staple_nutrition(description)
    if staple is not None:
        scaled = scale_nutrition(staple, grams) if grams is not None else staple
        return [(staple.source, scaled)]
    return [
        (nutrition.source, nutrition)
        for nutrition in off_candidates(description, grams)
    ]


def suggest_foods(
    query: str,
    limit: int = 6,
) -> list[tuple[str, Nutrition]]:
    """Return live autocomplete suggestions: banked foods, then matching staples.

    The user's own logged foods rank first (they are the most likely repeats);
    built-in staples fill any remaining slots so common whole foods surface even
    before they have ever been logged.  A staple already covered by a banked
    name is not duplicated.

    Args:
        query: Free-text the user has typed so far.
        limit: Maximum number of suggestions to return.

    Returns:
        ``(display_name, Nutrition)`` pairs, ranked, at most ``limit`` long.
    """
    results = list(search_foods(query, limit))
    seen = {name.casefold() for name, _ in results}
    for name, nutrition in suggest_staples(query, limit):
        if name.casefold() not in seen:
            results.append((name, nutrition))
    return results[:limit]
