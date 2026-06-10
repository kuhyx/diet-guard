"""The user's personal food bank: a local corpus of previously logged foods.

Every food the user logs is remembered here with its full macros, keyed by a
normalized name.  The gate's autocomplete searches *only* this corpus -- never
Open Food Facts.  OFF (in :mod:`python_pkg.diet_guard._estimator`) is used only
to *fill in* the macros of a brand-new food the first time it is entered; from
then on the food is served from the bank, so search quality improves with use
and works fully offline.

Search is intentionally typo-tolerant.  Rather than a prefix/exact match, it
combines substring containment with :func:`difflib.SequenceMatcher` similarity
(stdlib -- no extra dependency), so "chiken breast" still finds "chicken
breast".  Results are ranked by match quality, then by how often the food has
been logged, so your staples float to the top.
"""

from __future__ import annotations

import json
import logging
import time
from typing import TYPE_CHECKING

from python_pkg.diet_guard._constants import FOOD_BANK_FILE
from python_pkg.diet_guard._estimator import Nutrition
from python_pkg.diet_guard._fuzzy import match_score
from python_pkg.diet_guard._meal import MealItem, meal_total

if TYPE_CHECKING:
    from collections.abc import Sequence

_logger = logging.getLogger(__name__)

# Below this similarity ratio a non-substring candidate is not a plausible typo
# of the query and is dropped.  SequenceMatcher's own "close match" default is
# 0.6; we reuse it so behavior matches difflib intuitions.
_FUZZY_THRESHOLD = 0.6
# Default number of autocomplete suggestions to surface.
DEFAULT_SUGGESTIONS = 8

# On-disk shape: {normalized_name: {"desc", "kcal", "protein_g", "carbs_g",
# "fat_g", "grams", "count"}}.  ``count`` ranks frequently eaten staples first.
BankRecord = dict[str, object]


def _normalize(description: str) -> str:
    """Return the lookup key for a description (trimmed, case-folded)."""
    return description.strip().casefold()


def _read_bank() -> dict[str, BankRecord]:
    """Read the food bank from disk (empty dict on any error).

    A corrupt or unreadable file is moved aside (see
    :func:`_quarantine_corrupt_bank`) rather than re-warned about on every call:
    the gate reads the bank on each keystroke, so a single bad file would
    otherwise flood the journal and then be silently overwritten by the next
    write.
    """
    if not FOOD_BANK_FILE.exists():
        return {}
    try:
        with FOOD_BANK_FILE.open() as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        _quarantine_corrupt_bank()
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        key: value
        for key, value in data.items()
        if isinstance(key, str) and isinstance(value, dict)
    }


def _quarantine_corrupt_bank() -> None:
    """Move an unreadable bank aside to a timestamped backup, warning once.

    Renaming the bad file means the next read finds nothing and returns an empty
    bank quietly (no per-keystroke warning flood), the next write starts a fresh
    bank, and the original is preserved for manual recovery instead of being
    silently overwritten and lost.
    """
    backup = FOOD_BANK_FILE.with_name(
        f"{FOOD_BANK_FILE.name}.corrupt-{int(time.time())}",
    )
    try:
        FOOD_BANK_FILE.rename(backup)
    except OSError:
        _logger.warning(
            "Food bank %s is unreadable and cannot be moved", FOOD_BANK_FILE
        )
        return
    _logger.warning(
        "Food bank %s was unreadable; moved aside to %s and starting fresh",
        FOOD_BANK_FILE,
        backup,
    )


def _write_bank(bank: dict[str, BankRecord]) -> None:
    """Persist the food bank to disk, creating the data directory if needed."""
    FOOD_BANK_FILE.parent.mkdir(parents=True, exist_ok=True)
    with FOOD_BANK_FILE.open("w") as handle:
        json.dump(bank, handle, indent=2, sort_keys=True)


def _record_to_nutrition(record: BankRecord) -> Nutrition:
    """Build a :class:`Nutrition` from a stored bank record.

    Missing or non-numeric fields default to 0.0 so a hand-edited or partial
    record can never raise while the user is mid-log.

    Args:
        record: A stored food-bank record.

    Returns:
        The reconstructed Nutrition (source marked as the food bank).
    """
    return Nutrition(
        kcal=_as_float(record.get("kcal")),
        protein_g=_as_float(record.get("protein_g")),
        carbs_g=_as_float(record.get("carbs_g")),
        fat_g=_as_float(record.get("fat_g")),
        grams=_as_float(record.get("grams")),
        source="food bank",
    )


def _as_float(value: object) -> float:
    """Coerce a stored field to float, defaulting to 0.0 (bools rejected)."""
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    return 0.0


def remember_food(description: str, nutrition: Nutrition) -> None:
    """Record (or refresh) a food in the bank, bumping its use count.

    The latest macros win, so correcting a food's calories once fixes every
    future suggestion.  A blank description is ignored.

    Args:
        description: The user's free-text food name.
        nutrition: The macros to store for it.
    """
    _upsert(description, nutrition, components=None)


def remember_meal(name: str, items: Sequence[MealItem]) -> Nutrition:
    """Bank each component and the composite meal, returning the summed macros.

    Each item is remembered on its own (so it autocompletes next time) and the
    meal is stored as one entry carrying its summed macros plus its component
    names, so the whole meal can be re-picked later as a single summed food.  A
    blank meal name still banks the items but stores no empty-keyed composite.

    Args:
        name: The composite meal's name (e.g. ``"dinner"``).
        items: The meal's components, each with its own nutrition.

    Returns:
        The summed nutrition for the whole meal.
    """
    for item in items:
        remember_food(item.name, item.nutrition)
    total = meal_total(items)
    _upsert(name, total, components=[item.name for item in items])
    return total


def _upsert(
    description: str,
    nutrition: Nutrition,
    *,
    components: list[str] | None,
) -> None:
    """Insert or refresh one bank record, bumping its use count.

    Shared by :func:`remember_food` (a single food) and :func:`remember_meal`
    (a composite, which additionally records its ``components``).  A blank
    description is ignored, so an unnamed entry is never stored.

    Args:
        description: The food or meal name (its normalized form is the key).
        nutrition: The macros to store.
        components: Component names for a composite meal, or None for a food.
    """
    key = _normalize(description)
    if not key:
        return
    bank = _read_bank()
    previous = bank.get(key, {})
    count = _as_float(previous.get("count")) + 1
    record: BankRecord = {
        "desc": description.strip(),
        "kcal": nutrition.kcal,
        "protein_g": nutrition.protein_g,
        "carbs_g": nutrition.carbs_g,
        "fat_g": nutrition.fat_g,
        "grams": nutrition.grams,
        "count": count,
    }
    if components is not None:
        record["components"] = list(components)
    bank[key] = record
    _write_bank(bank)


def lookup_food(description: str) -> Nutrition | None:
    """Return the exact-match macros for ``description``, or None.

    Args:
        description: The food name to look up verbatim (case-insensitive).

    Returns:
        The stored Nutrition, or None if the food is not banked.
    """
    record = _read_bank().get(_normalize(description))
    return _record_to_nutrition(record) if record is not None else None


def _display_name(record: BankRecord, key: str) -> str:
    """Return a record's display name, falling back to its key."""
    desc = record.get("desc")
    return desc if isinstance(desc, str) and desc.strip() else key


def search_foods(
    query: str,
    limit: int = DEFAULT_SUGGESTIONS,
) -> list[tuple[str, Nutrition]]:
    """Return banked foods matching ``query``, best match first.

    An empty query returns the most-logged foods (the expandable full list).
    A non-empty query keeps substring and close-typo matches, ranked by match
    quality then by use count.

    Args:
        query: Free-text the user has typed so far.
        limit: Maximum number of suggestions to return.

    Returns:
        ``(display_name, Nutrition)`` pairs, ranked, at most ``limit`` long.
    """
    bank = _read_bank()
    normalized = _normalize(query)
    if not normalized:
        return _ranked_all(bank, limit)

    scored: list[tuple[float, float, str, Nutrition]] = []
    for key, record in bank.items():
        score = match_score(normalized, key)
        if score < _FUZZY_THRESHOLD:
            continue
        count = _as_float(record.get("count"))
        scored.append(
            (score, count, _display_name(record, key), _record_to_nutrition(record)),
        )
    # Sort by score then frequency, both descending.
    scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return [(name, nutrition) for _, _, name, nutrition in scored[:limit]]


def _ranked_all(
    bank: dict[str, BankRecord],
    limit: int,
) -> list[tuple[str, Nutrition]]:
    """Return all banked foods ranked by use count, most-logged first."""
    ranked = sorted(
        bank.items(),
        key=lambda item: _as_float(item[1].get("count")),
        reverse=True,
    )
    return [
        (_display_name(record, key), _record_to_nutrition(record))
        for key, record in ranked[:limit]
    ]
