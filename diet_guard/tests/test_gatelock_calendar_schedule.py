"""Tests for the schedule row's ``HH:MM`` comboboxes.

Covers :mod:`._gatelock_calendar_schedule`: the quarter-hour choices, the
Up/Down step that avoids posting the dropdown over a grabbed lock, and the
per-widget state toggle in :mod:`._gatelock_scheduleedit`.
"""

from __future__ import annotations

from types import SimpleNamespace
from typing import TYPE_CHECKING, cast
from unittest.mock import patch

import pytest

from diet_guard._gatelock_calendar_schedule import TIME_CHOICES, step_time
from diet_guard.tests._tk_fakes import _FakeTclError

if TYPE_CHECKING:
    from collections.abc import Callable

    from diet_guard._gatelock import MealGate
    from diet_guard.tests._tk_fakes import FakeCombobox


class TestChoices:
    def test_every_quarter_hour_of_the_day(self) -> None:
        assert len(TIME_CHOICES) == 96
        assert TIME_CHOICES[:3] == ("00:00", "00:15", "00:30")
        assert TIME_CHOICES[-1] == "23:45"


class TestStepTime:
    @pytest.mark.parametrize(
        ("text", "direction", "expected"),
        [
            ("07:15", 1, "07:30"),
            ("07:15", -1, "07:00"),
            # Off-grid steps to the neighbouring mark, not by a flat 15.
            ("07:23", 1, "07:30"),
            ("07:23", -1, "07:15"),
            ("7", 1, "07:15"),
            # Clamped to the day's grid.
            ("00:00", -1, "00:00"),
            ("23:45", 1, "23:45"),
            ("23:50", 1, "23:45"),
        ],
    )
    def test_steps_onto_the_grid(
        self, text: str, direction: int, expected: str
    ) -> None:
        assert step_time(text, direction) == expected

    def test_half_typed_text_is_left_alone(self) -> None:
        assert step_time("07:", 1) == "07:"


class TestComboBindings:
    def _fire(self, gate: MealGate, key: str) -> object:
        combo = cast("FakeCombobox", gate._cal_widgets.schedule_first_entry)
        handler = cast("Callable[[object], object]", combo.bindings[key])
        return handler(None)

    def test_up_down_step_only_while_editing(self, gate: MealGate) -> None:
        gate._cal_vars.schedule.first.set("08:00")
        # Locked: the key is swallowed and the value is unchanged.
        assert self._fire(gate, "<Up>") == "break"
        assert gate._cal_vars.schedule.first.get() == "08:00"

        gate._on_edit_or_save_schedule()
        assert self._fire(gate, "<Up>") == "break"
        assert gate._cal_vars.schedule.first.get() == "08:15"
        self._fire(gate, "<Down>")
        self._fire(gate, "<Down>")
        assert gate._cal_vars.schedule.first.get() == "07:45"


class TestArrowNeverPosts:
    """The popdown would map beneath the lock yet hold the grab."""

    def _press(self, gate: MealGate, x: int) -> object:
        combo = cast("FakeCombobox", gate._cal_widgets.schedule_last_entry)
        handler = cast("Callable[[object], object]", combo.bindings["<ButtonPress-1>"])
        return handler(SimpleNamespace(x=x, y=5))

    def test_a_click_on_the_arrow_is_swallowed(self, gate: MealGate) -> None:
        gate._on_edit_or_save_schedule()
        assert self._press(gate, 60) == "break"

    def test_a_click_on_the_text_reaches_ttk(self, gate: MealGate) -> None:
        """So the caret still lands where the user clicked."""
        gate._on_edit_or_save_schedule()
        assert self._press(gate, 10) is None


class TestStateToggle:
    def test_one_dead_widget_does_not_skip_the_rest(self, gate: MealGate) -> None:
        """A vanished monitor's combobox must not leave the others locked."""
        widgets = gate._cal_widgets
        dead = _FakeTclError("dead")
        with patch.object(widgets.schedule_first_entry, "config", side_effect=dead):
            gate._set_schedule_entry_state("normal")
        assert widgets.schedule_last_entry.configured["state"] == "normal"
        assert widgets.schedule_count_entry.configured["state"] == "normal"
