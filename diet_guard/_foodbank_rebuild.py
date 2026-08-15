"""Rebuilding the derived food bank from the meal log.

Split out of :mod:`._foodbank` to keep both files under the repo's 250-line
limit.  The sync tick calls :func:`rebuild_food_bank` after a merge.  It *does*
persist, but through :mod:`._foodbank`'s private ``_write_bank`` rather than
opening the file here, so ``FOOD_BANK_FILE`` stays named by :mod:`._foodbank`
alone -- which is what ``tests/conftest.py`` redirects, and what
``test_state_redirect.py`` enforces.
"""

from __future__ import annotations

from diet_guard._coerce import as_float
from diet_guard._estimator import Nutrition
from diet_guard._foodbank import BankRecord, _apply_upsert, _write_bank

__all__ = ["rebuild_food_bank"]


def _entry_nutrition(entry: dict[str, object], *, source: str) -> Nutrition:
    """Build a :class:`Nutrition` from a raw log entry's macro fields."""
    return Nutrition(
        kcal=as_float(entry.get("kcal")),
        protein_g=as_float(entry.get("protein_g")),
        carbs_g=as_float(entry.get("carbs_g")),
        fat_g=as_float(entry.get("fat_g")),
        grams=as_float(entry.get("grams")),
        source=source,
    )


def rebuild_food_bank(log: dict[str, list[dict[str, object]]]) -> dict[str, BankRecord]:
    """Rebuild the bank from scratch by replaying ``log``'s entries, then persist it.

    Replays in a fixed, device-independent order (by ``time`` then ``id``),
    so two devices that converge on the same merged log also converge on the
    same bank -- this is what lets the food bank stay *derived*, never
    synced, with no counter-merge (CRDT) logic needed for ``count``.  Mirrors
    the Dart port's ``FoodBankService.rebuild`` exactly, including the
    composite-meal branch (banks each component, then the composite itself).

    Deleted (tombstoned) entries are skipped entirely, same as
    :func:`diet_guard._state.load_log`.

    Args:
        log: A full log keyed by date, e.g. from
            :func:`diet_guard._state.read_raw_log` after a sync merge.

    Returns:
        The freshly rebuilt bank (also written to disk).
    """
    entries = sorted(
        (
            entry
            for day_entries in log.values()
            for entry in day_entries
            if not entry.get("deleted")
        ),
        key=lambda entry: (str(entry.get("time", "")), str(entry.get("id", ""))),
    )
    bank: dict[str, BankRecord] = {}
    for entry in entries:
        components = entry.get("components")
        component_names: list[str] | None = None
        if isinstance(components, list):
            component_names = []
            for component in components:
                if not isinstance(component, dict):
                    continue
                name = str(component.get("name", ""))
                component_names.append(name)
                _apply_upsert(
                    bank,
                    name,
                    _entry_nutrition(component, source="food bank"),
                    components=None,
                )
        _apply_upsert(
            bank,
            str(entry.get("desc", "")),
            _entry_nutrition(entry, source=str(entry.get("source", "manual"))),
            components=component_names,
        )
    _write_bank(bank)
    return bank
