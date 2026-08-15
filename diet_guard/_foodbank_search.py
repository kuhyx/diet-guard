"""Lookup and ranked search over the food banks.

Split out of :mod:`._foodbank` to keep both files under the repo's 250-line
limit.  Read-only: everything here goes through :func:`._foodbank.read_food_bank`
and the curated bank, so ``FOOD_BANK_FILE`` stays named by :mod:`._foodbank`
alone -- which is what ``tests/conftest.py`` redirects, and what
``test_state_redirect.py`` enforces.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._coerce import as_float
from diet_guard._foodbank import (
    DEFAULT_SUGGESTIONS,
    BankRecord,
    _normalize,
    _read_bank,
    _record_to_nutrition,
)
from diet_guard._foodbank_manual import read_manual_bank
from diet_guard._fuzzy import match_score

if TYPE_CHECKING:
    from diet_guard._estimator import Nutrition

# Minimum SequenceMatcher ratio for a fuzzy name match to be offered.
_FUZZY_THRESHOLD = 0.6

__all__ = ["_all_records", "lookup_food", "search_foods"]


def _all_records() -> dict[str, BankRecord]:
    """Return curated entries merged under the log-derived ones.

    Log-derived records win on a name collision: they carry a real ``count``
    and the macros the food was actually logged with, whereas a curated entry
    is only a starting point.  Mirrors ``foodbank_service.dart``'s
    ``{...manualBank, ...logBank}``.
    """
    return {**read_manual_bank(), **_read_bank()}


def lookup_food(description: str) -> Nutrition | None:
    """Return the exact-match macros for ``description``, or None.

    Searches curated entries as well as logged ones, so a food added by hand
    on either device resolves here too.

    Args:
        description: The food name to look up verbatim (case-insensitive).

    Returns:
        The stored Nutrition, or None if the food is not banked.
    """
    record = _all_records().get(_normalize(description))
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
    quality then by use count.  Searches curated entries (added by hand on
    either device, see :mod:`diet_guard._foodbank_manual`) as well as logged
    ones; a logged record wins on a name collision.

    Args:
        query: Free-text the user has typed so far.
        limit: Maximum number of suggestions to return.

    Returns:
        ``(display_name, Nutrition)`` pairs, ranked, at most ``limit`` long.
    """
    bank = _all_records()
    normalized = _normalize(query)
    if not normalized:
        return _ranked_all(bank, limit)

    scored: list[tuple[float, float, str, Nutrition]] = []
    for key, record in bank.items():
        score = match_score(normalized, key)
        if score < _FUZZY_THRESHOLD:
            continue
        count = as_float(record.get("count"))
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
        key=lambda item: as_float(item[1].get("count")),
        reverse=True,
    )
    return [
        (_display_name(record, key), _record_to_nutrition(record))
        for key, record in ranked[:limit]
    ]
