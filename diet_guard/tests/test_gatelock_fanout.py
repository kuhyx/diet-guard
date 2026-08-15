"""Per-output fan-out: the point of the gatelock v0.2.0 migration.

Every other test here runs against the single-output default, where "the gate
is on every monitor" and "the gate is on the primary and nowhere else" are
indistinguishable. These run on a two-monitor desk, so a loop that only ever
touched the first surface fails here and nowhere else.
"""

from __future__ import annotations

from contextlib import ExitStack
import tkinter as tk
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

from diet_guard import _gatelock_calendar
from diet_guard._gatelock import MealGate
from diet_guard.tests.conftest import (
    _FAKE_TK,
    _FAKE_TTK,
    _GATE_TK_MODULES,
    TWO_OUTPUTS,
)

if TYPE_CHECKING:
    from collections.abc import Iterator


@pytest.fixture
def dual_gate(dual_output: None) -> Iterator[MealGate]:
    """A demo gate built across two live outputs."""
    del dual_output
    with ExitStack() as stack:
        for module in _GATE_TK_MODULES:
            stack.enter_context(patch.object(module, "tk", _FAKE_TK))
        stack.enter_context(patch.object(_gatelock_calendar, "ttk", _FAKE_TTK))
        yield MealGate(demo_mode=True)


class TestGateFansOut:
    """The gate as it is actually built on a two-monitor desk."""

    def test_one_gate_per_output(self, dual_gate: MealGate) -> None:
        """The premise the rest of this class rests on."""
        assert len(dual_gate._widgets.bundles) == len(TWO_OUTPUTS)

    def test_every_output_gets_its_own_widgets(self, dual_gate: MealGate) -> None:
        """Two distinct forms, not two references to one."""
        boxes = [bundle.desc_text for bundle in dual_gate._widgets.bundles]
        assert len({id(box) for box in boxes}) == len(TWO_OUTPUTS)

    def test_typing_an_amount_is_shared_across_monitors(
        self, dual_gate: MealGate
    ) -> None:
        """Entries are variable-backed, so both screens agree without syncing."""
        dual_gate._widgets.amount_entry.insert(0, "250")

        assert dual_gate._vars.entries.amount.get() == "250"
        assert dual_gate._widgets.amount_entry.get() == "250"

    def test_description_written_to_every_monitor(self, dual_gate: MealGate) -> None:
        """The description box has no variable, so writes must reach each copy."""
        dual_gate._set_desc("shoarma")

        for bundle in dual_gate._widgets.bundles:
            assert "shoarma" in bundle.desc_text.get("1.0", "end-1c")

    def test_description_read_from_the_monitor_typed_on(
        self, dual_gate: MealGate
    ) -> None:
        """Typing on the second screen is still what gets logged."""
        first, second = dual_gate._widgets.bundles
        first.desc_text.delete("1.0", tk.END)
        second.desc_text.delete("1.0", tk.END)
        second.desc_text.insert("1.0", "late dinner")

        assert dual_gate._get_desc() == "late dinner"

    def test_suggestions_listed_on_every_monitor(self, dual_gate: MealGate) -> None:
        """The picker is filled on both screens, not just the primary."""
        dual_gate._widgets.suggestion_box.delete(0, tk.END)
        dual_gate._widgets.suggestion_box.insert(tk.END, "apple")

        for bundle in dual_gate._widgets.bundles:
            assert bundle.suggestion_box._items == ["apple"]

    def test_calendar_grid_repainted_on_every_monitor(
        self, dual_gate: MealGate
    ) -> None:
        """The History tab exists per surface and every copy is redrawn."""
        assert len(dual_gate._cal_surfaces) == len(TWO_OUTPUTS)
        for surface in dual_gate._cal_surfaces:
            for cell in surface.day_cells:
                cell.configured.clear()

        dual_gate._refresh_calendar()

        for surface in dual_gate._cal_surfaces:
            assert any(cell.configured for cell in surface.day_cells)

    def test_budget_controls_toggle_on_every_monitor(self, dual_gate: MealGate) -> None:
        """Unlocking the budget field unlocks it on both screens."""
        dual_gate._on_edit_or_save_budget()

        for surface in dual_gate._cal_surfaces:
            assert surface.budget_entry.configured.get("state") == "normal"
            assert surface.budget_edit_button.configured.get("text") == "Save"

    def test_frame_group_covers_every_monitor(self, dual_gate: MealGate) -> None:
        """The outer frame is exposed per surface, for tab selection."""
        frames = list(dual_gate._widgets.frame)

        assert len(frames) == len(TWO_OUTPUTS)
        assert frames[0] is dual_gate._widgets.bundles[0].frame

    def test_a_dark_output_drops_only_its_own_copy(self, dual_gate: MealGate) -> None:
        """Teardown is by output name, so the surviving monitor keeps working."""
        survivor = dual_gate._widgets.bundles[1]

        dual_gate.teardown_surface(MagicMock(output_name=TWO_OUTPUTS[0].name))

        assert dual_gate._widgets.bundles == [survivor]
