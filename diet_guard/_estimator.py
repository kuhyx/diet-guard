"""Calorie/macro estimation backends for diet_guard.

The default backend queries the public Open Food Facts (OFF) database over
HTTP -- no API key required.  It is strongest for branded/packaged foods
(fast food included, which is the binge target) and weaker for generic
home-cooked descriptions; in the latter case the caller should fall back to a
manual ``--kcal`` value.

The backend is intentionally small and pluggable: replace :func:`estimate`
with a local-LLM (ollama) or remote-LLM implementation later without touching
the log/state or CLI layers.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import logging

_logger = logging.getLogger(__name__)

# Open Food Facts nutriment field names (values are "per 100 g").
_OFF_KCAL_FIELD = "energy-kcal_100g"
_OFF_PROTEIN_FIELD = "proteins_100g"
_OFF_CARBS_FIELD = "carbohydrates_100g"
_OFF_FAT_FIELD = "fat_100g"
_GRAMS_PER_REFERENCE = 100.0


@dataclass(frozen=True)
class Nutrition:
    """Estimated nutrition for one logged portion of food.

    Attributes:
        kcal: Total energy for the portion, in kilocalories.
        protein_g: Protein for the portion, in grams.
        carbs_g: Carbohydrate for the portion, in grams.
        fat_g: Fat for the portion, in grams.
        grams: Portion size used for the estimate, in grams (0 if unknown).
        source: Human-readable provenance, e.g. ``"openfoodfacts: Big Mac"``
            or ``"manual"``.
    """

    kcal: float
    protein_g: float
    carbs_g: float
    fat_g: float
    grams: float
    source: str


def _as_float(value: object) -> float | None:
    """Coerce an Open Food Facts numeric field to ``float``.

    OFF returns numbers as ints, floats, or numeric strings depending on the
    product, so accept all three.  ``bool`` is rejected even though it is an
    ``int`` subtype, since a boolean nutriment value is meaningless.

    Args:
        value: The raw field value.

    Returns:
        The value as a float, or None if it is not numeric.
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def manual(
    kcal: float,
    grams: float | None = None,
    *,
    protein_g: float = 0.0,
    carbs_g: float = 0.0,
    fat_g: float = 0.0,
) -> Nutrition:
    """Build a :class:`Nutrition` from user-supplied values.

    Calories are required; the three macros are optional so the offline path
    stays low-friction (a bare ``--kcal`` always works) while a user who knows
    the full breakdown can record it and seed the food bank with it.

    Args:
        kcal: Calories the user entered directly.
        grams: Optional portion size, kept only for display.
        protein_g: Protein in grams (0 if unknown).
        carbs_g: Carbohydrate in grams (0 if unknown).
        fat_g: Fat in grams (0 if unknown).

    Returns:
        A Nutrition with the supplied macros and ``source="manual"``.
    """
    return Nutrition(
        kcal=round(float(kcal), 1),
        protein_g=round(float(protein_g), 1),
        carbs_g=round(float(carbs_g), 1),
        fat_g=round(float(fat_g), 1),
        grams=round(float(grams), 1) if grams is not None else 0.0,
        source="manual",
    )


def scale_nutrition(nutrition: Nutrition, grams: float) -> Nutrition:
    """Rescale a portion's macros to a new weight in grams (pure).

    A banked or looked-up food stores the macros for *some* portion; eating a
    different amount must scale every macro proportionally, so 200 g of a food
    banked at 100 g logs double the calories.  When the basis portion is unknown
    (``grams == 0``) there is nothing to scale from, so the macros are kept and
    only the recorded weight is updated -- best effort rather than a wrong
    number.

    Args:
        nutrition: The basis nutrition (its ``grams`` is the basis weight).
        grams: The new portion weight in grams.

    Returns:
        A new Nutrition scaled to ``grams`` (source preserved).
    """
    if nutrition.grams <= 0 or grams <= 0:
        return replace(nutrition, grams=grams if grams > 0 else nutrition.grams)
    factor = grams / nutrition.grams
    return replace(
        nutrition,
        kcal=round(nutrition.kcal * factor, 1),
        protein_g=round(nutrition.protein_g * factor, 1),
        carbs_g=round(nutrition.carbs_g * factor, 1),
        fat_g=round(nutrition.fat_g * factor, 1),
        grams=round(grams, 1),
    )
