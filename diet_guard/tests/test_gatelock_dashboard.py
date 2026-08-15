"""Tests for the nutrition model, lookup, and meal-building flow of MealGate.

Covers :mod:`._gatelock_nutrition` (reference -> total maths, suggestions,
unit toggling) and :mod:`._gatelock_mealflow` (submit/lookup/record, the
dashboard, and multi-item meals).  The functional fake ``tk`` widgets and the
``gate`` fixture live in ``conftest.py`` and are shared with
:mod:`test_gatelock`.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _gatelock_mealflow
from diet_guard._budget import write_budget
from diet_guard._state import log_meal
from diet_guard.tests.conftest import _nutrition

if TYPE_CHECKING:
    from diet_guard._gatelock import MealGate


class TestDashboard:
    """The running calorie/macro panel."""

    def test_headline_with_budget(self, gate: MealGate) -> None:
        """A sealed budget shows consumed/target/remaining."""
        write_budget(2000)
        gate._refresh_dashboard()
        assert "left" in gate._vars.cal_headline.get()

    def test_headline_without_budget(self, gate: MealGate) -> None:
        """With no budget, only today's total is shown."""
        gate._refresh_dashboard()
        assert "kcal today" in gate._vars.cal_headline.get()

    def test_dashboard_lists_entries(self, gate: MealGate) -> None:
        """Logged entries appear in the detail panel."""
        write_budget(2000, weight_kg=80)
        log_meal("apple", _nutrition(95, 100), 8)
        gate._refresh_dashboard()
        text = gate._vars.dashboard.get()
        assert "apple" in text
        assert "protein" in text

    def test_dashboard_empty(self, gate: MealGate) -> None:
        """With nothing logged, the panel says so."""
        gate._refresh_dashboard()
        assert "nothing logged yet" in gate._vars.dashboard.get()

    def test_slot_header_variants(self, gate: MealGate) -> None:
        """The header covers none / one / several pending slots."""
        gate._pending = []
        gate._refresh_slot_header()
        assert "All meals logged" in gate._vars.slot_header.get()
        gate._pending = [8]
        gate._refresh_slot_header()
        assert "Log your" in gate._vars.slot_header.get()
        gate._pending = [8, 12]
        gate._refresh_slot_header()
        assert "remaining" in gate._vars.slot_header.get()

    def test_projection_with_budget(self, gate: MealGate) -> None:
        """The projection shows the after-this-item remaining when priced."""
        write_budget(2000)
        gate._widgets.macros.kcal.insert(0, "300")
        gate._refresh_projection()
        assert "after this item" in gate._vars.projection.get()


class TestSlotWalk:
    """Slot tagging and the per-slot input reset."""

    def test_slot_for_log_demo_is_none(self, gate: MealGate) -> None:
        """A demo gate tags logs with no real slot."""
        gate._pending = [8]
        assert gate._slot_for_log() is None

    def test_slot_for_log_production_is_slot(self, gate: MealGate) -> None:
        """A production gate tags logs with the current slot."""
        gate.demo_mode = False
        gate._pending = [12]
        assert gate._slot_for_log() == 12

    def test_clear_inputs_resets_the_form(self, gate: MealGate) -> None:
        """Clearing between slots empties the description and the macros."""
        gate._set_desc("salad")
        gate._widgets.macros.kcal.insert(0, "80")
        gate._clear_inputs()
        assert gate._get_desc() == ""
        assert gate._widgets.macros.kcal.get() == ""

    def test_finish_slot_unlocks_on_last(self, gate: MealGate) -> None:
        """Finishing the final slot triggers unlock."""
        gate._pending = [20]
        with patch.object(gate, "_unlock") as unlock:
            gate._finish_slot("done")
        unlock.assert_called_once()


class TestFetchFromSync:
    """The manual "Fetch from sync" button on the lock screen."""

    def test_demo_mode_does_not_sync(self, gate: MealGate) -> None:
        """In demo the button is inert and never touches the network."""
        with patch.object(_gatelock_mealflow, "pull_shared_log") as pull:
            gate._on_fetch_sync()
        pull.assert_not_called()
        assert "only available on the real lock" in gate._vars.status.get()

    def test_pull_failure_keeps_lock(self, gate: MealGate) -> None:
        """A failed pull shows the reason and leaves pending slots intact."""
        gate.demo_mode = False
        gate._pending = [8, 12]
        with patch.object(
            _gatelock_mealflow,
            "pull_shared_log",
            return_value="sync unavailable (x)",
        ):
            gate._on_fetch_sync()
        assert gate._pending == [8, 12]
        assert "still locked" in gate._vars.status.get()

    def test_no_new_meals_keeps_all_slots(self, gate: MealGate) -> None:
        """A clean pull that satisfies nothing reports so and keeps the slots."""
        gate.demo_mode = False
        gate._pending = [8, 12]
        with (
            patch.object(_gatelock_mealflow, "pull_shared_log", return_value=None),
            patch.object(_gatelock_mealflow, "due_slots", return_value=(8, 12)),
        ):
            gate._on_fetch_sync()
        assert gate._pending == [8, 12]
        assert "No new meals" in gate._vars.status.get()

    def test_partial_advances_to_next_slot(self, gate: MealGate) -> None:
        """One slot pulled in leaves the rest; the window advances (singular)."""
        gate.demo_mode = False
        gate._pending = [8, 12]
        with (
            patch.object(_gatelock_mealflow, "pull_shared_log", return_value=None),
            patch.object(_gatelock_mealflow, "due_slots", return_value=(12,)),
        ):
            gate._on_fetch_sync()
        assert gate._pending == [12]
        assert "Pulled 1 meal " in gate._vars.status.get()

    def test_partial_plural_wording(self, gate: MealGate) -> None:
        """Two slots pulled in uses the plural 'meals'."""
        gate.demo_mode = False
        gate._pending = [8, 12, 16]
        with (
            patch.object(_gatelock_mealflow, "pull_shared_log", return_value=None),
            patch.object(_gatelock_mealflow, "due_slots", return_value=(16,)),
        ):
            gate._on_fetch_sync()
        assert gate._pending == [16]
        assert "Pulled 2 meals" in gate._vars.status.get()

    def test_all_satisfied_unlocks(self, gate: MealGate) -> None:
        """When the pull satisfies every pending slot, the gate unlocks."""
        gate.demo_mode = False
        gate._pending = [8, 12]
        with (
            patch.object(_gatelock_mealflow, "pull_shared_log", return_value=None),
            patch.object(_gatelock_mealflow, "due_slots", return_value=()),
        ):
            gate._on_fetch_sync()
        assert gate._pending == []
        assert "unlocking" in gate._vars.status.get()
