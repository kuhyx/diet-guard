"""Turning an estimate into one logged entry: slot, write, result data.

The slot rule (``docs/DOCS-claude-relay.md`` section 4) only *calls*
``_slots`` and ``_gate``; no slot arithmetic lives here.

* ``"due"``: the oldest elapsed-but-unlogged slot of today; with nothing due
  (already logged elsewhere, free or sick day, hold, outside the enforcement
  window) the ordinary ``slot_for_log`` rule, never an error.
* ``"normal"``: ``nearest_slot`` of the phone's ``client_slot_min``.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._claude_contract import entry_id_for
from diet_guard._estimator import Nutrition
from diet_guard._gate import due_slots
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._slot_wire import entry_slot_minute
from diet_guard._slots import nearest_slot, slot_for_log
from diet_guard._state_sync import find_entry, log_meal_as

if TYPE_CHECKING:
    from datetime import datetime

    from diet_guard._claude_contract import MealRequest
    from diet_guard._claude_schema import Estimate

#: ``Nutrition.source`` and so the entry's ``source`` field.
SOURCE = "claude"


def resolve_slot(request: MealRequest, now: datetime) -> int:
    """The slot minute this request's meal is logged under."""
    if request.mode == "due":
        due = due_slots(now)
        return due[0] if due else slot_for_log(now, current_schedule())
    return nearest_slot(request.client_slot_min, current_schedule())


def result_data(entry: dict[str, object]) -> dict[str, object]:
    """The ``logged`` result fields of a stored entry."""
    slot = entry_slot_minute(entry)
    return {
        "entry_id": entry["id"],
        "desc": entry["desc"],
        "grams": entry["grams"],
        "kcal": entry["kcal"],
        "protein_g": entry["protein_g"],
        "carbs_g": entry["carbs_g"],
        "fat_g": entry["fat_g"],
        "slot_min": slot,
        "time": entry["time"],
    }


def already_logged(rid: str) -> dict[str, object] | None:
    """The result data of ``rid``'s entry if it was logged before, else None."""
    entry = find_entry(entry_id_for(rid))
    return result_data(entry) if entry is not None else None


def log_estimate(
    rid: str, estimate: Estimate, request: MealRequest, now: datetime
) -> dict[str, object]:
    """Log ``estimate`` for request ``rid`` and return its result data.

    Idempotent: the entry id is derived from ``rid``, and an entry that
    already carries it is returned untouched instead of logged again.
    """
    if (existing := already_logged(rid)) is not None:
        return existing
    nutrition = Nutrition(
        kcal=estimate.kcal,
        protein_g=estimate.protein_g,
        carbs_g=estimate.carbs_g,
        fat_g=estimate.fat_g,
        grams=estimate.grams,
        source=SOURCE,
    )
    components = [dict(item) for item in estimate.components or ()] or None
    entry = log_meal_as(
        entry_id_for(rid),
        estimate.desc,
        nutrition,
        resolve_slot(request, now),
        components=components,
    )
    return result_data(entry)
