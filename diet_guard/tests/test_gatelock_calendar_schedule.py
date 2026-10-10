"""Tests for the schedule row's ``HH:MM`` spinboxes.

Covers :mod:`._gatelock_calendar_schedule`: the quarter-hour step and its
clamps, the ``<<Increment>>``/``<<Decrement>>`` bindings that replace ttk's own
spin logic, and the per-widget state toggle in :mod:`._gatelock_scheduleedit`.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, cast
from unittest.mock import patch

import pytest

from diet_guard._gatelock_calendar_schedule import LAST_RANGE, step_time
from diet_guard.tests._tk_fakes import _FakeTclError

if TYPE_CHECKING:
    from collections.abc import Callable

    from diet_guard._gatelock import MealGate
    from diet_guard.tests._tk_fakes import FakeSpinbox


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
            # Clamped to the first meal's range: 00:00..23:45.
            ("00:00", -1, "00:00"),
            ("23:45", 1, "23:45"),
            ("23:50", 1, "23:45"),
        ],
    )
    def test_steps_onto_the_grid(
        self, text: str, direction: int, expected: str
    ) -> None:
        assert step_time(text, direction) == expected

    def test_the_last_meal_never_steps_below_00_15(self) -> None:
        """It must sit one grid step after the earliest possible first meal."""
        assert step_time("00:15", -1, LAST_RANGE) == "00:15"
        assert step_time("00:20", -1, LAST_RANGE) == "00:15"
        assert step_time("23:45", 1, LAST_RANGE) == "23:45"

    def test_half_typed_text_is_left_alone(self) -> None:
        assert step_time("07:", 1) == "07:"


def _spin(gate: MealGate, which: str, event: str) -> object:
    """Fire one of a spinbox's step events, as ttk would on press/key/wheel."""
    widget = getattr(gate._cal_widgets, f"schedule_{which}_entry")
    spin = cast("FakeSpinbox", widget)
    handler = cast("Callable[[object], object]", spin.bindings[event])
    return handler(None)


class TestSpinEvents:
    def test_steps_only_while_editing(self, gate: MealGate) -> None:
        gate._cal_vars.schedule.first.set("08:00")
        # Locked: the event is swallowed and the value is unchanged.
        assert _spin(gate, "first", "<<Increment>>") == "break"
        assert gate._cal_vars.schedule.first.get() == "08:00"

        gate._on_edit_or_save_schedule()
        assert _spin(gate, "first", "<<Increment>>") == "break"
        assert gate._cal_vars.schedule.first.get() == "08:15"
        _spin(gate, "first", "<<Decrement>>")
        _spin(gate, "first", "<<Decrement>>")
        assert gate._cal_vars.schedule.first.get() == "07:45"

    def test_an_off_grid_value_steps_to_its_neighbour(self, gate: MealGate) -> None:
        gate._on_edit_or_save_schedule()
        gate._cal_vars.schedule.last.set("19:23")
        _spin(gate, "last", "<<Increment>>")
        assert gate._cal_vars.schedule.last.get() == "19:30"

    def test_the_last_field_uses_its_own_clamp(self, gate: MealGate) -> None:
        gate._on_edit_or_save_schedule()
        gate._cal_vars.schedule.last.set("00:15")
        _spin(gate, "last", "<<Decrement>>")
        assert gate._cal_vars.schedule.last.get() == "00:15"


class TestStateToggle:
    def test_one_dead_widget_does_not_skip_the_rest(self, gate: MealGate) -> None:
        """A vanished monitor's spinbox must not leave the others locked."""
        widgets = gate._cal_widgets
        dead = _FakeTclError("dead")
        with patch.object(widgets.schedule_first_entry, "configure", side_effect=dead):
            gate._set_schedule_entry_state("normal")
        assert widgets.schedule_last_entry.configured["state"] == "normal"
        assert widgets.schedule_count_entry.configured["state"] == "normal"
