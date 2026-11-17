"""The food-bank rows handed to the estimator.

The skill looks the bank up first (kuhy's own logged numbers beat generic
ones), but the whole bank would bloat every prompt. So the rows are the
closest matches for each part of the typed meal plus the most-logged staples,
deduplicated. Curated and log-derived rows both come through
:func:`diet_guard._foodbank_search.search_foods`.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING, Final

from diet_guard._foodbank_search import search_foods

if TYPE_CHECKING:
    from diet_guard._estimator import Nutrition

#: Splits a meal typed as a list: commas, plus, "i"/"oraz"/"and"/"with".
_PARTS: Final = re.compile(
    r"\s*(?:,|;|\+|\bi\b|\boraz\b|\band\b|\bz\b)\s*", re.IGNORECASE
)
PER_QUERY: Final = 4
STAPLES: Final = 6
MAX_ROWS: Final = 20


def _row(name: str, nutrition: Nutrition) -> str:
    """One bank row as a compact line the model can scale."""
    return (
        f"{name} | {nutrition.grams:g} g | {nutrition.kcal:g} kcal | "
        f"P{nutrition.protein_g:g} C{nutrition.carbs_g:g} F{nutrition.fat_g:g}"
    )


def bank_rows(text: str | None) -> list[str]:
    """Bank rows relevant to ``text``, best first, at most :data:`MAX_ROWS`.

    A photo-only request (``text`` None or blank) gets the staples alone.
    """
    queries = [text.strip()] if text and text.strip() else []
    queries += [part for part in _PARTS.split(text or "") if part.strip()]
    rows: dict[str, str] = {}
    for query in dict.fromkeys(queries):
        for name, nutrition in search_foods(query, PER_QUERY):
            rows.setdefault(name.casefold(), _row(name, nutrition))
    for name, nutrition in search_foods("", STAPLES):
        rows.setdefault(name.casefold(), _row(name, nutrition))
    return list(rows.values())[:MAX_ROWS]
