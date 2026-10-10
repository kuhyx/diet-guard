"""Tests for _state.py — the HMAC-signed daily food log.

State files are redirected into ``tmp_path`` and a deterministic HMAC key is
provided by the autouse conftest fixtures, so signing, verification, and the
defensive read paths are all exercised in isolation.
"""

from __future__ import annotations

import json

import pytest

from diet_guard import _state
from diet_guard._budget import BudgetNotInitializedError, write_budget
from diet_guard._estimator import Nutrition
from diet_guard._meal_schedule import MealSchedule
from diet_guard._meal_schedule_store import record_schedule_change
from diet_guard._state import (
    log_meal,
)
from diet_guard._state_today import (
    consumption_band,
    logged_slots_today,
    remaining_budget,
)


def _nut(
    kcal: float, *, protein: float = 0, carbs: float = 0, fat: float = 0
) -> Nutrition:
    """Build a Nutrition for a logged meal."""
    return Nutrition(kcal, protein, carbs, fat, 100, "manual")


def _raw() -> dict[str, list[dict[str, object]]]:
    """Read the raw log file as parsed JSON (no verification)."""
    return json.loads(_state.FOOD_LOG_FILE.read_text(encoding="utf-8"))


class TestLoggedSlots:
    """Which slots today's log has satisfied."""

    def test_int_slots_counted(self) -> None:
        """Whole-hour slot minutes are reported as the slots they are."""
        log_meal("a", _nut(1), slot=480)
        log_meal("b", _nut(1), slot=720)
        assert logged_slots_today() == {480, 720}

    def test_bool_slot_excluded(self) -> None:
        """A bool masquerading as a slot is ignored."""
        log_meal("a", _nut(1), slot=480)
        raw = _raw()
        day = next(iter(raw))
        raw[day].append({"kcal": 1, "slot": True})
        _state.FOOD_LOG_FILE.write_text(json.dumps(raw), encoding="utf-8")
        assert logged_slots_today() == {480}

    def test_an_off_hour_slot_is_written_and_read_as_minutes(self) -> None:
        """07:15 survives the round trip through disk and the HMAC check."""
        record_schedule_change(MealSchedule(435, 1140, 5))
        log_meal("a", _nut(1), slot=435)
        assert logged_slots_today() == {435}

    def test_a_legacy_hour_entry_counts_toward_the_nearest_slot(self) -> None:
        """An old ``{"slot": 7}`` entry still covers a 07:15 checkpoint."""
        record_schedule_change(MealSchedule(435, 1140, 5))
        log_meal("a", _nut(1), slot=420)
        assert logged_slots_today() == {435}

    def test_an_explicit_schedule_is_snapped_onto(self) -> None:
        """The caller's schedule wins over the stored one."""
        log_meal("a", _nut(1), slot=480)
        assert logged_slots_today(MealSchedule(495, 1200, 4)) == {495}


class TestBudgetViews:
    """Remaining budget and the qualitative band."""

    def test_remaining_requires_budget(self) -> None:
        """With no budget sealed, remaining_budget raises."""
        with pytest.raises(BudgetNotInitializedError):
            remaining_budget()

    def test_remaining_value(self) -> None:
        """Remaining is budget minus today's total."""
        write_budget(2000)
        log_meal("lunch", _nut(500), slot=720)
        assert remaining_budget() == 1500.0

    def test_band_on_track(self) -> None:
        """Well under the warn fraction is 'on track'."""
        write_budget(2000)
        log_meal("a", _nut(500), slot=480)
        assert consumption_band() == "on track"

    def test_band_approaching(self) -> None:
        """At or above the warn fraction but under budget is 'approaching limit'."""
        write_budget(2000)
        log_meal("a", _nut(1700), slot=480)
        assert consumption_band() == "approaching limit"

    def test_band_over(self) -> None:
        """At or above budget is 'OVER BUDGET'."""
        write_budget(2000)
        log_meal("a", _nut(2100), slot=480)
        assert consumption_band() == "OVER BUDGET"
