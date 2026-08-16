"""Tests for the gate History tab's meal-schedule row.

Covers :mod:`._gatelock_scheduleedit`.  The functional fake ``tk`` widgets and
the ``gate`` fixture live in ``conftest.py``, shared with the other gate
tests.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._gatelock_scheduleedit import schedule_summary
from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule
from diet_guard._meal_schedule_store import current_schedule, record_schedule_change

if TYPE_CHECKING:
    from diet_guard._gatelock import MealGate


def _type(gate: MealGate, first: str, last: str, count: str) -> None:
    """Fill the three schedule entries as the user would."""
    gate._cal_vars.schedule.first.set(first)
    gate._cal_vars.schedule.last.set(last)
    gate._cal_vars.schedule.count.set(count)


class TestScheduleSummary:
    """The derived-times label."""

    def test_lists_every_checkpoint(self) -> None:
        """The label spells out the hours the schedule derives."""
        assert schedule_summary(MealSchedule(8, 20, 5)) == (
            "08:00  11:00  14:00  17:00  20:00"
        )


class TestEditToggle:
    """The Edit/Save button's two states."""

    def test_first_click_unlocks_without_saving(self, gate: MealGate) -> None:
        """Clicking Edit opens the fields but persists nothing yet."""
        gate._on_edit_or_save_schedule()

        assert gate._cal_editing_schedule
        assert current_schedule() == DEFAULT_SCHEDULE

    def test_second_click_persists_and_relocks(self, gate: MealGate) -> None:
        """Clicking Save validates, writes, and returns to read-only."""
        gate._on_edit_or_save_schedule()
        _type(gate, "8", "20", "5")
        gate._on_edit_or_save_schedule()

        assert not gate._cal_editing_schedule
        assert current_schedule() == MealSchedule(8, 20, 5)
        assert gate._cal_vars.schedule.status.get() == "Saved."

    def test_a_failed_save_leaves_editing_open(self, gate: MealGate) -> None:
        """A bad value can be corrected rather than silently discarded."""
        gate._on_edit_or_save_schedule()
        _type(gate, "20", "8", "4")
        gate._on_edit_or_save_schedule()

        assert gate._cal_editing_schedule
        assert current_schedule() == DEFAULT_SCHEDULE


class TestValidation:
    """Rejected input, with the reason shown rather than silently clamped."""

    def test_rejects_non_numeric(self, gate: MealGate) -> None:
        """Letters in an hour field are refused, not coerced."""
        _type(gate, "eight", "20", "4")

        assert not gate._save_schedule_entry()
        assert "whole hours" in gate._cal_vars.schedule.status.get()

    def test_rejects_a_backwards_window(self, gate: MealGate) -> None:
        """The last meal must come after the first."""
        _type(gate, "20", "8", "4")

        assert not gate._save_schedule_entry()
        assert "before the last" in gate._cal_vars.schedule.status.get()

    def test_rejects_an_out_of_range_hour(self, gate: MealGate) -> None:
        """Hours outside 0-23 are refused."""
        _type(gate, "8", "25", "4")

        assert not gate._save_schedule_entry()
        assert "0-23" in gate._cal_vars.schedule.status.get()

    def test_rejects_too_few_meals(self, gate: MealGate) -> None:
        """One meal a day is below the supported range."""
        _type(gate, "8", "20", "1")

        assert not gate._save_schedule_entry()
        assert "Meals per day" in gate._cal_vars.schedule.status.get()

    def test_rejects_too_many_meals(self, gate: MealGate) -> None:
        """More than the cap is refused."""
        _type(gate, "8", "20", "9")

        assert not gate._save_schedule_entry()
        assert "Meals per day" in gate._cal_vars.schedule.status.get()

    def test_rejects_more_meals_than_the_window_holds(self, gate: MealGate) -> None:
        """A narrow window cannot hold six distinct whole-hour checkpoints.

        Without this the derivation would round two meals onto the same hour,
        and a duplicate slot silently drops a checkpoint.
        """
        _type(gate, "8", "11", "6")

        assert not gate._save_schedule_entry()
        assert "Too many meals" in gate._cal_vars.schedule.status.get()


class TestDisplay:
    """Showing the stored schedule in the row."""

    def test_shows_the_stored_schedule(self, gate: MealGate) -> None:
        """The fields and the derived-times label reflect what is stored."""
        gate._show_schedule(MealSchedule(7, 21, 3))

        assert gate._cal_vars.schedule.first.get() == "7"
        assert gate._cal_vars.schedule.last.get() == "21"
        assert gate._cal_vars.schedule.count.get() == "3"
        assert gate._cal_vars.schedule.times.get() == "07:00  14:00  21:00"

    def test_a_refresh_does_not_clobber_an_open_edit(self, gate: MealGate) -> None:
        """Typing survives a calendar refresh landing mid-edit."""
        gate._on_edit_or_save_schedule()
        _type(gate, "6", "22", "6")
        gate._refresh_calendar()

        assert gate._cal_vars.schedule.first.get() == "6"

    def test_a_refresh_shows_the_stored_schedule_when_idle(
        self, gate: MealGate
    ) -> None:
        """Outside an edit the row tracks whatever is stored."""
        record_schedule_change(MealSchedule(9, 19, 3))
        gate._refresh_calendar()

        assert gate._cal_vars.schedule.first.get() == "9"
        assert gate._cal_vars.schedule.times.get() == "09:00  14:00  19:00"
