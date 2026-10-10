"""Tests for the gate History tab's meal-schedule row.

Covers :mod:`._gatelock_scheduleedit` and the row's widgets in
:mod:`._gatelock_calendar_schedule`.  The functional fake ``tk``/``ttk``
widgets and the ``gate`` fixture live in ``conftest.py``, shared with the
other gate tests.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

import pytest

from diet_guard._gatelock_scheduleedit import schedule_problem, schedule_summary
from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule
from diet_guard._meal_schedule_store import current_schedule, record_schedule_change

if TYPE_CHECKING:
    from diet_guard._gatelock import MealGate


def _type(gate: MealGate, first: str, last: str, count: str) -> None:
    """Fill the three schedule fields as the user would."""
    gate._cal_vars.schedule.first.set(first)
    gate._cal_vars.schedule.last.set(last)
    gate._cal_vars.schedule.count.set(count)


def _status(gate: MealGate) -> str:
    return gate._cal_vars.schedule.status.get()


class TestScheduleSummary:
    """The derived-times label."""

    def test_lists_every_checkpoint(self) -> None:
        """The label spells out the times the schedule derives."""
        assert schedule_summary(MealSchedule(480, 1200, 5)) == (
            "08:00  11:00  14:00  17:00  20:00"
        )

    def test_an_off_hour_schedule_shows_its_minutes(self) -> None:
        assert schedule_summary(MealSchedule(435, 1140, 5)) == (
            "07:15  10:15  13:15  16:00  19:00"
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
        _type(gate, "07:15", "19:00", "5")
        gate._on_edit_or_save_schedule()

        assert not gate._cal_editing_schedule
        assert current_schedule() == MealSchedule(435, 1140, 5)
        assert _status(gate) == "Saved."
        assert gate._cal_vars.schedule.times.get().startswith("07:15  10:15")

    def test_a_bare_hour_is_still_accepted(self, gate: MealGate) -> None:
        """Typing ``8`` means 08:00, as it did before minutes existed."""
        _type(gate, "8", "20", "5")

        assert gate._save_schedule_entry()
        assert current_schedule() == MealSchedule(480, 1200, 5)
        assert gate._cal_vars.schedule.first.get() == "08:00"

    def test_a_failed_save_leaves_editing_open(self, gate: MealGate) -> None:
        """A bad value can be corrected rather than silently discarded."""
        gate._on_edit_or_save_schedule()
        _type(gate, "20:00", "08:00", "4")
        gate._on_edit_or_save_schedule()

        assert gate._cal_editing_schedule
        assert current_schedule() == DEFAULT_SCHEDULE

    def test_the_comboboxes_lock_as_disabled_not_readonly(self, gate: MealGate) -> None:
        """A ``readonly`` ttk combobox still lets the list edit a locked row."""
        widgets = gate._cal_widgets
        gate._on_edit_or_save_schedule()
        assert widgets.schedule_first_entry.configured["state"] == "normal"
        assert widgets.schedule_count_entry.configured["state"] == "normal"

        _type(gate, "07:15", "19:00", "5")
        gate._on_edit_or_save_schedule()
        assert widgets.schedule_first_entry.configured["state"] == "disabled"
        assert widgets.schedule_last_entry.configured["state"] == "disabled"
        assert widgets.schedule_count_entry.configured["state"] == "readonly"


class TestValidation:
    """Rejected input, with the reason shown rather than silently clamped."""

    @pytest.mark.parametrize("first", ["eight", "7:5", "24:00", "07:60", ""])
    def test_rejects_a_time_that_is_not_hhmm(self, gate: MealGate, first: str) -> None:
        _type(gate, first, "20:00", "4")

        assert not gate._save_schedule_entry()
        assert "HH:MM" in _status(gate)

    def test_rejects_a_non_numeric_count(self, gate: MealGate) -> None:
        _type(gate, "08:00", "20:00", "five")

        assert not gate._save_schedule_entry()
        assert "meals per day as a number" in _status(gate)

    @pytest.mark.parametrize(
        ("first", "last", "count", "reason"),
        [
            ("20:00", "08:00", "4", "at least 15 min after"),
            ("08:00", "08:14", "2", "at least 15 min after"),
            ("08:00", "20:00", "1", "Meals per day must be 2-6."),
            ("08:00", "20:00", "9", "Meals per day must be 2-6."),
            ("08:00", "08:45", "5", "Too many meals"),
        ],
    )
    def test_rejects_what_normalize_would_silently_change(
        self, gate: MealGate, first: str, last: str, count: str, reason: str
    ) -> None:
        _type(gate, first, last, count)

        assert not gate._save_schedule_entry()
        assert reason in _status(gate)
        assert current_schedule() == DEFAULT_SCHEDULE

    def test_the_narrowest_legal_window_is_accepted(self, gate: MealGate) -> None:
        """15 min holds two meals; 45 min holds four (one per quarter hour)."""
        _type(gate, "08:00", "08:45", "4")

        assert gate._save_schedule_entry()
        assert current_schedule().slots() == (480, 495, 510, 525)

    def test_an_accepted_schedule_is_stored_unchanged(self) -> None:
        """No rule here is looser than ``normalized()``: what passes is kept."""
        for first in range(0, 1440, 37):
            for last in range(first + 15, 1440, 53):
                for count in range(2, 7):
                    schedule = MealSchedule(first, last, count)
                    if schedule_problem(schedule) is None:
                        assert schedule.normalized() == schedule


class TestDisplay:
    """Showing the stored schedule in the row."""

    def test_shows_the_stored_schedule(self, gate: MealGate) -> None:
        """The fields and the derived-times label reflect what is stored."""
        gate._show_schedule(MealSchedule(435, 1260, 3))

        assert gate._cal_vars.schedule.first.get() == "07:15"
        assert gate._cal_vars.schedule.last.get() == "21:00"
        assert gate._cal_vars.schedule.count.get() == "3"
        assert gate._cal_vars.schedule.times.get() == "07:15  14:15  21:00"

    def test_a_refresh_does_not_clobber_an_open_edit(self, gate: MealGate) -> None:
        """Typing survives a calendar refresh landing mid-edit."""
        gate._on_edit_or_save_schedule()
        _type(gate, "06:00", "22:00", "6")
        gate._refresh_calendar()

        assert gate._cal_vars.schedule.first.get() == "06:00"

    def test_a_refresh_shows_the_stored_schedule_when_idle(
        self, gate: MealGate
    ) -> None:
        """Outside an edit the row tracks whatever is stored."""
        record_schedule_change(MealSchedule(540, 1140, 3))
        gate._refresh_calendar()

        assert gate._cal_vars.schedule.first.get() == "09:00"
        assert gate._cal_vars.schedule.times.get() == "09:00  14:00  19:00"
