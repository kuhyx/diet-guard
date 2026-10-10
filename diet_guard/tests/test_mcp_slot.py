"""The MCP ``log_meal`` tool's ``slot`` argument: ``"HH:MM"`` or a legacy hour.

Kept apart from ``test_mcp.py`` for the repo's file-length cap.  These run
against the real (redirected) schedule store rather than a patched
``day_slots``, so "is this one of today's slots?" is answered the way the gate
answers it.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from diet_guard import _mcp
from diet_guard._estimator import Nutrition
from diet_guard._meal_schedule import MealSchedule
from diet_guard._meal_schedule_store import record_schedule_change

_MEAL = Nutrition(250.0, 10.0, 20.0, 5.0, 150.0, "manual")


def _preview(slot: int | str) -> dict[str, object]:
    """Preview a log with ``slot`` (never writes: ``confirm`` stays False)."""
    with patch.object(_mcp, "resolve_nutrition", return_value=_MEAL):
        return _mcp.log_meal("apple", slot=slot)


class TestSlotArgument:
    def test_an_hhmm_string_names_an_off_hour_slot(self) -> None:
        record_schedule_change(MealSchedule(435, 1140, 5))
        assert _preview("07:15")["target_slot"] == 435

    def test_a_legacy_int_hour_is_read_as_that_hour(self) -> None:
        """``12`` is 12:00 -- never 00:12, which is what a bare minute would be."""
        assert _preview(12)["target_slot"] == 720

    def test_an_hh_string_is_a_whole_hour(self) -> None:
        assert _preview("20")["target_slot"] == 1200

    @pytest.mark.parametrize(
        ("slot", "reason"),
        [
            ("13:00", "13:00 is not a meal slot today"),
            (13, "13:00 is not a meal slot today"),
            ("noon", "invalid time"),
            (25, "is not an hour 0-23"),
            (-1, "is not an hour 0-23"),
            (True, "is not an hour 0-23"),
        ],
    )
    def test_anything_but_one_of_todays_slots_is_refused(
        self, slot: int | str, reason: str
    ) -> None:
        """A clear reason, and nothing resolved or written."""
        with patch.object(_mcp, "record_meal") as record:
            out = _preview(slot)
        record.assert_not_called()
        assert out["ok"] is False
        assert reason in str(out["reason"])

    def test_the_refusal_lists_the_valid_slots(self) -> None:
        record_schedule_change(MealSchedule(435, 1140, 5))
        reason = str(_preview("07:00")["reason"])
        assert "07:15, 10:15, 13:15, 16:00, 19:00" in reason
