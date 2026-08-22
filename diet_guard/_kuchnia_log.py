"""Turn confirmed catering dishes into log entries.

Nothing here runs without an explicit confirmation from the user -- that is the
whole design of this feature.  A delivered meal is not an eaten meal: if the
importer wrote entries unattended, the gate would auto-satisfy the exact
checkpoint it exists to enforce, and the log would record what the courier
dropped off rather than what was eaten.

Duplicate suppression works off **today's log**, not a local "already
imported" marker.  ``log_meal`` mints a fresh uuid per entry, so a re-import
after a lost marker would merge as duplicates on every peer; comparing against
the synced log instead is robust to marker loss *and* correct across devices --
if the phone already logged the dish, the PC sees it and skips.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._estimator import Nutrition
from diet_guard._state import log_meal
from diet_guard._state_today import today_entries

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Sequence

    from diet_guard._kuchnia_spread import SlottedDish

#: Marks entries this importer created, so the provenance is visible in the log
#: and in the food bank's ``source`` column.
SOURCE = "kuchnia wikinga"


def _already_logged(entries: Sequence[dict[str, object]], name: str, slot: int) -> bool:
    """Return True when today's log already holds this dish in this slot."""
    wanted = name.strip().casefold()
    return any(
        str(entry.get("desc", "")).strip().casefold() == wanted
        and entry.get("slot") == slot
        for entry in entries
    )


def log_dishes(chosen: Sequence[SlottedDish]) -> list[str]:
    """Log each chosen dish, skipping any already logged today in that slot.

    Args:
        chosen: The dishes the user confirmed, already paired with slots.

    Returns:
        The descriptions actually written, in the order they were logged.
    """
    entries = today_entries()
    written: list[str] = []
    for item in chosen:
        dish = item.dish
        if _already_logged(entries, dish.name, item.slot):
            continue
        log_meal(
            dish.name,
            Nutrition(
                kcal=dish.kcal,
                protein_g=dish.protein_g,
                carbs_g=dish.carbs_g,
                fat_g=dish.fat_g,
                grams=dish.grams,
                source=SOURCE,
            ),
            item.slot,
        )
        # Reflect the write locally so two identical dishes in one batch do not
        # both land: today_entries() was read once, before the loop.
        entries = [*entries, {"desc": dish.name, "slot": item.slot}]
        written.append(dish.name)
    return written
