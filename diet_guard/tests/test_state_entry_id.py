"""``log_meal(entry_id=...)`` and ``find_entry``: what makes a replay find itself."""

from __future__ import annotations

from diet_guard._estimator import Nutrition
from diet_guard._state import log_meal
from diet_guard._state_sync import find_entry, log_meal_as

FOOD = Nutrition(kcal=100, protein_g=1, carbs_g=2, fat_g=3, grams=50, source="claude")


def test_given_entry_id_is_used_and_found() -> None:
    """The id the caller picks is the stored id, and find_entry returns it."""
    entry = log_meal_as("fixed-id", "owsianka", FOOD, 480)
    assert entry["id"] == "fixed-id"
    found = find_entry("fixed-id")
    assert found is not None
    assert found["desc"] == "owsianka"


def test_default_id_is_still_a_fresh_uuid() -> None:
    """Without entry_id nothing changes: two meals, two distinct ids."""
    first = log_meal("a", FOOD, 480)
    second = log_meal("a", FOOD, 480)
    assert first["id"] != second["id"]


def test_find_entry_sees_a_tombstoned_entry() -> None:
    """A deleted entry still counts as logged: a replay must not re-log it."""
    log_meal_as("gone", "a", FOOD, 480)
    from diet_guard._state_sync import undo_last_today

    assert undo_last_today() is not None
    found = find_entry("gone")
    assert found is not None
    assert found["deleted"]


def test_find_entry_unknown_is_none() -> None:
    """No such id: None, no exception."""
    assert find_entry("never-logged") is None
