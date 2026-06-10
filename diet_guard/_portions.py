"""Built-in portion knowledge: unit weights and macros for common staples.

Two problems this solves, both seen in real use:

* **Counting by the piece.**  People eat "5 apples", not "910 grams of apple".
  To turn a count into grams the program needs to know what one piece weighs.
* **Open Food Facts is wrong for bare generics.**  Searching OFF for "apple"
  returns a packaged apple *pastry* (~500 kcal), not the fruit.  For staple
  whole foods a small, offline, curated table is both more correct and faster.

So this module gives diet_guard, for each common countable food, the typical
mass of one piece and its macros per 100 g.  It is consulted *before* Open Food
Facts (see :mod:`python_pkg.diet_guard._resolve`), so a bare staple resolves
locally and sensibly, and a count multiplies cleanly into grams.

The numbers are deliberately round "good enough" averages (USDA ballpark); the
goal is a sane estimate the user can override with an explicit weight, not lab
precision.
"""

from __future__ import annotations

from dataclasses import dataclass

from python_pkg.diet_guard._estimator import Nutrition
from python_pkg.diet_guard._fuzzy import match_score

# Same close-match bar the food bank uses, so matching feels consistent.
_MATCH_THRESHOLD = 0.6
# Assumed mass of one piece when a counted food is not in the table, so "3 of
# something" still produces a number (flagged to the user as an assumption).
DEFAULT_ITEM_GRAMS = 100.0


@dataclass(frozen=True)
class Staple:
    """A common whole food: typical piece weight and per-100 g macros.

    Attributes:
        name: Canonical lowercase food name matched against the description.
        unit_grams: Typical mass of one piece, in grams.
        kcal_100: Calories per 100 g.
        protein_100: Protein grams per 100 g.
        carbs_100: Carbohydrate grams per 100 g.
        fat_100: Fat grams per 100 g.
    """

    name: str
    unit_grams: float
    kcal_100: float
    protein_100: float
    carbs_100: float
    fat_100: float


# Per-100 g macros with one typical piece weight, for the common countable
# foods.  Ordered roughly by how often they are eaten by the piece.
_STAPLES: tuple[Staple, ...] = (
    Staple("apple", 182, 52, 0.3, 14.0, 0.2),
    Staple("banana", 118, 89, 1.1, 23.0, 0.3),
    Staple("orange", 131, 47, 0.9, 12.0, 0.1),
    Staple("egg", 50, 143, 13.0, 1.1, 9.5),
    Staple("boiled egg", 50, 155, 13.0, 1.1, 11.0),
    Staple("slice of bread", 28, 265, 9.0, 49.0, 3.2),
    Staple("potato", 173, 77, 2.0, 17.0, 0.1),
    Staple("tomato", 123, 18, 0.9, 3.9, 0.2),
    Staple("carrot", 61, 41, 0.9, 10.0, 0.2),
    Staple("pear", 178, 57, 0.4, 15.0, 0.1),
    Staple("peach", 150, 39, 0.9, 10.0, 0.3),
    Staple("kiwi", 69, 61, 1.1, 15.0, 0.5),
    Staple("mandarin", 74, 53, 0.8, 13.0, 0.3),
    Staple("clementine", 74, 47, 0.9, 12.0, 0.2),
    Staple("plum", 66, 46, 0.7, 11.0, 0.3),
    Staple("strawberry", 12, 32, 0.7, 7.7, 0.3),
    Staple("slice of pizza", 107, 266, 11.0, 33.0, 10.0),
    Staple("rice cake", 9, 387, 8.0, 82.0, 2.8),
)


def _best_staple(description: str) -> Staple | None:
    """Return the staple best matching ``description``, or None below threshold.

    Args:
        description: Free-text food name (e.g. ``"apple"``, ``"apples"``).

    Returns:
        The closest :class:`Staple`, or None if nothing clears the match bar.
    """
    key = description.strip().casefold()
    if not key:
        return None
    best: Staple | None = None
    best_score = _MATCH_THRESHOLD
    for staple in _STAPLES:
        score = match_score(key, staple.name)
        if score > best_score:
            best = staple
            best_score = score
    return best


def estimate_unit_grams(description: str) -> float | None:
    """Return the typical grams of one piece of ``description``, or None.

    Args:
        description: Free-text food name.

    Returns:
        The unit weight in grams for a known staple, else None (the caller then
        falls back to :data:`DEFAULT_ITEM_GRAMS` and tells the user it guessed).
    """
    staple = _best_staple(description)
    return staple.unit_grams if staple is not None else None


def _staple_to_nutrition(staple: Staple) -> Nutrition:
    """Return a staple's per-100 g :class:`Nutrition` (source ``"staple: name"``)."""
    return Nutrition(
        kcal=staple.kcal_100,
        protein_g=staple.protein_100,
        carbs_g=staple.carbs_100,
        fat_g=staple.fat_100,
        grams=100.0,
        source=f"staple: {staple.name}",
    )


def staple_nutrition(description: str) -> Nutrition | None:
    """Return per-100 g :class:`Nutrition` for a known staple, else None.

    The grams are fixed at 100 so the result is a clean reference basis the
    caller can rescale to the actual amount eaten via
    :func:`python_pkg.diet_guard._estimator.scale_nutrition`.

    Args:
        description: Free-text food name.

    Returns:
        The staple's per-100 g Nutrition (source ``"staple: <name>"``), or None.
    """
    staple = _best_staple(description)
    return _staple_to_nutrition(staple) if staple is not None else None


def suggest_staples(
    query: str,
    limit: int = 6,
) -> list[tuple[str, Nutrition]]:
    """Return staples whose name matches ``query``, best match first.

    Used to surface built-in whole foods in the gate's live autocomplete (so
    typing "apple" suggests the staple immediately, without a separate lookup
    step), alongside the user's banked foods.

    Args:
        query: Free-text the user has typed so far.
        limit: Maximum number of suggestions to return.

    Returns:
        ``(name, per-100 g Nutrition)`` pairs, ranked, at most ``limit`` long.
    """
    key = query.strip().casefold()
    if not key:
        return []
    scored: list[tuple[float, Staple]] = []
    for staple in _STAPLES:
        score = match_score(key, staple.name)
        if score >= _MATCH_THRESHOLD:
            scored.append((score, staple))
    scored.sort(key=lambda item: item[0], reverse=True)
    return [(staple.name, _staple_to_nutrition(staple)) for _, staple in scored[:limit]]
