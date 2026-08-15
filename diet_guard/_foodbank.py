"""The user's personal food bank: a local corpus of previously logged foods.

Every food the user logs is remembered here with its full macros, keyed by a
normalized name.  The gate's autocomplete searches *only* this corpus -- never
Open Food Facts.  OFF (in :mod:`diet_guard._estimator`) is used only
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

from diet_guard._coerce import as_float
from diet_guard._constants import FOOD_BANK_FILE
from diet_guard._estimator import Nutrition

_logger = logging.getLogger(__name__)

# Below this similarity ratio a non-substring candidate is not a plausible typo
# of the query and is dropped.  SequenceMatcher's own "close match" default is
# 0.6; we reuse it so behavior matches difflib intuitions.
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


def read_food_bank() -> dict[str, BankRecord]:
    """Return the derived bank verbatim, for the sync layer."""
    return _read_bank()


def write_food_bank(bank: dict[str, BankRecord]) -> None:
    """Persist a merged derived bank, for the sync layer."""
    _write_bank(bank)


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
        kcal=as_float(record.get("kcal")),
        protein_g=as_float(record.get("protein_g")),
        carbs_g=as_float(record.get("carbs_g")),
        fat_g=as_float(record.get("fat_g")),
        grams=as_float(record.get("grams")),
        source="food bank",
    )


def remember_food(description: str, nutrition: Nutrition) -> None:
    """Record (or refresh) a food in the bank, bumping its use count.

    The latest macros win, so correcting a food's calories once fixes every
    future suggestion.  A blank description is ignored.

    Args:
        description: The user's free-text food name.
        nutrition: The macros to store for it.
    """
    _upsert(description, nutrition, components=None)


def _apply_upsert(
    bank: dict[str, BankRecord],
    description: str,
    nutrition: Nutrition,
    *,
    components: list[str] | None,
) -> None:
    """Insert or refresh one record in ``bank`` in place, bumping its count.

    Pure (no I/O), so it is shared by the disk-backed :func:`_upsert` and by
    :func:`rebuild_food_bank`, which replays a whole log into a fresh
    in-memory bank without a read/write round trip per entry.  A blank
    description is ignored, so an unnamed entry is never stored.

    Args:
        bank: The in-memory bank to update.
        description: The food or meal name (its normalized form is the key).
        nutrition: The macros to store.
        components: Component names for a composite meal, or None for a food.
    """
    key = _normalize(description)
    if not key:
        return
    previous = bank.get(key, {})
    count = as_float(previous.get("count")) + 1
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


def _upsert(
    description: str,
    nutrition: Nutrition,
    *,
    components: list[str] | None,
) -> None:
    """Insert or refresh one bank record on disk, bumping its use count.

    The ``components`` path is now only reached by
    :func:`rebuild_food_bank` replaying composite entries already in the log
    -- nothing creates a new one, but historical composites keep re-banking
    their parts.

    Args:
        description: The food or meal name (its normalized form is the key).
        nutrition: The macros to store.
        components: Component names for a composite meal, or None for a food.
    """
    bank = _read_bank()
    _apply_upsert(bank, description, nutrition, components=components)
    _write_bank(bank)
