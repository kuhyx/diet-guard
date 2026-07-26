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


class TestReferenceModel:
    """The reference -> total nutrition computation."""

    def test_reference_none_without_calories(self, gate: MealGate) -> None:
        """No calories typed means no reference yet."""
        assert gate._reference_nutrition() is None

    def test_current_is_reference_without_amount(self, gate: MealGate) -> None:
        """With calories but no amount, the reference stands in as the total."""
        gate._widgets.macros.kcal.insert(0, "200")
        current = gate._current_nutrition()
        assert current is not None
        assert current.kcal == 200

    def test_current_scales_with_amount(self, gate: MealGate) -> None:
        """Grams eaten scale the per-100 g reference into the total."""
        gate._widgets.macros.kcal.insert(0, "200")
        gate._widgets.amount_entry.insert(0, "200")
        current = gate._current_nutrition()
        assert current is not None
        assert current.kcal == 400


class TestSuggestions:
    """Autocomplete population and selection."""

    def test_keyrelease_items_mode_shows_weight(self, gate: MealGate) -> None:
        """In items mode, typing a staple fills the per-item weight."""
        gate._vars.unit.set("items")
        gate._set_desc("apple")
        gate._on_desc_keyrelease(None)
        assert gate._widgets.per_entry.get() == "182"

    def test_select_bank_fills_name_and_macros(self, gate: MealGate) -> None:
        """Picking a banked suggestion adopts its name and macros."""
        gate._state.suggestions = [("apple pie", _nutrition(300, 120))]
        gate._state.suggestion_mode = "bank"
        gate._widgets.suggestion_box.selection_set(0)
        gate._on_suggestion_select(None)
        assert gate._get_desc() == "apple pie"
        assert gate._widgets.macros.kcal.get() == "300"

    def test_select_candidate_keeps_description(self, gate: MealGate) -> None:
        """An OFF candidate fills macros but not the typed description."""
        gate._set_desc("my dish")
        gate._state.suggestions = [("openfoodfacts: X", _nutrition(250, 100))]
        gate._state.suggestion_mode = "candidates"
        gate._widgets.suggestion_box.selection_set(0)
        gate._on_suggestion_select(None)
        assert gate._get_desc() == "my dish"

    def test_select_no_selection(self, gate: MealGate) -> None:
        """No selection is a no-op."""
        gate._on_suggestion_select(None)

    def test_select_out_of_range(self, gate: MealGate) -> None:
        """A stale selection index beyond the list is ignored."""
        gate._state.suggestions = []
        gate._widgets.suggestion_box.selection_set(5)
        gate._on_suggestion_select(None)


class TestUnitToggle:
    """Switching the grams/items basis."""

    def test_toggle_reconverts_picked_food(self, gate: MealGate) -> None:
        """A picked food is re-expressed per item, then back per 100 g."""
        gate._apply_reference(_nutrition(52, 100), name="apple")
        gate._vars.unit.set("items")
        gate._on_unit_change("items")
        per_item = gate._widgets.macros.kcal.get()
        gate._vars.unit.set("grams")
        gate._on_unit_change("grams")
        assert gate._widgets.macros.kcal.get() == "52"
        assert per_item != "52"

    def test_toggle_without_reference_clears(self, gate: MealGate) -> None:
        """With no picked food, a toggle clears the macro fields."""
        gate._widgets.macros.kcal.insert(0, "123")
        gate._state.last_reference = None
        gate._vars.unit.set("items")
        gate._on_unit_change("items")
        assert gate._widgets.macros.kcal.get() == ""

    def test_macro_edit_drops_reference(self, gate: MealGate) -> None:
        """Hand-editing a macro invalidates the stored reference."""
        gate._state.last_reference = _nutrition()
        gate._on_macro_edit(None)
        assert gate._state.last_reference is None


class TestSubmit:
    """The two-step submit (look up, then log)."""

    def test_empty_description(self, gate: MealGate) -> None:
        """Submitting with no description prompts for one."""
        gate._on_submit()
        assert "Type what you ate" in gate._vars.status.get()

    def test_non_numeric_macros(self, gate: MealGate) -> None:
        """Non-numeric macros are rejected before logging."""
        gate._set_desc("apple")
        gate._widgets.macros.kcal.insert(0, "abc")
        gate._on_submit()
        assert "must be numbers" in gate._vars.status.get()

    def test_blank_calories_triggers_lookup(self, gate: MealGate) -> None:
        """A blank calorie field looks the food up rather than logging."""
        gate._set_desc("apple")
        with patch.object(gate, "_begin_lookup") as lookup:
            gate._on_submit()
        lookup.assert_called_once()

    def test_defensive_none_nutrition(self, gate: MealGate) -> None:
        """A calorie value but unresolvable nutrition prompts again (guard)."""
        gate._set_desc("apple")
        gate._widgets.macros.kcal.insert(0, "200")
        with patch.object(gate, "_current_nutrition", return_value=None):
            gate._on_submit()
        assert "Enter the calories" in gate._vars.status.get()

    def test_valid_submit_records(self, gate: MealGate) -> None:
        """A described, priced meal is recorded."""
        gate._set_desc("apple")
        gate._widgets.macros.kcal.insert(0, "95")
        with patch.object(gate, "_record") as record:
            gate._on_submit()
        record.assert_called_once()

    def test_on_return_submits(self, gate: MealGate) -> None:
        """Enter in a numeric field submits."""
        with patch.object(gate, "_on_submit") as submit:
            gate._on_return(None)
        submit.assert_called_once()


class TestLookup:
    """Step one: filling the form from a lookup."""

    def test_no_candidates(self, gate: MealGate) -> None:
        """No match asks for a manual value."""
        gate._set_desc("nonsense")
        with patch.object(_gatelock_mealflow, "lookup_candidates", return_value=[]):
            gate._begin_lookup("nonsense")
        assert "Couldn't look that up" in gate._vars.status.get()

    def test_single_candidate(self, gate: MealGate) -> None:
        """A single match fills the fields and invites review."""
        with patch.object(
            _gatelock_mealflow,
            "lookup_candidates",
            return_value=[("apple", _nutrition(95, 100))],
        ):
            gate._begin_lookup("apple")
        assert "Review the values" in gate._vars.status.get()

    def test_multiple_candidates(self, gate: MealGate) -> None:
        """Several matches invite picking another."""
        with patch.object(
            _gatelock_mealflow,
            "lookup_candidates",
            return_value=[
                ("a", _nutrition(95, 100)),
                ("b", _nutrition(120, 100)),
            ],
        ):
            gate._begin_lookup("apple")
        assert "pick another" in gate._vars.status.get()


class TestRecord:
    """Logging a meal and advancing the slot walk."""

    def test_demo_logs_without_slot(self, gate: MealGate) -> None:
        """A demo record banks the food but tags no real slot."""
        gate._pending = [8]
        with patch.object(_gatelock_mealflow, "log_meal") as log:
            gate._record("apple", _nutrition(95, 100))
        assert log.call_args.args[2] is None

    def test_last_slot_unlocks(self, gate: MealGate) -> None:
        """Recording the final pending slot triggers the unlock."""
        gate._pending = [8]
        with (
            patch.object(_gatelock_mealflow, "log_meal"),
            patch.object(_gatelock_mealflow, "remember_food"),
            patch.object(gate, "_unlock") as unlock,
        ):
            gate._record("apple", _nutrition(95, 100))
        unlock.assert_called_once()

    def test_more_slots_continue(self, gate: MealGate) -> None:
        """With slots remaining, the form clears and prompts the next."""
        gate._pending = [8, 12]
        with (
            patch.object(_gatelock_mealflow, "log_meal"),
            patch.object(_gatelock_mealflow, "remember_food"),
        ):
            gate._record("apple", _nutrition(95, 100))
        assert gate._pending == [12]
        assert "next meal" in gate._vars.status.get()

    def test_unlock_schedules_close(self, gate: MealGate) -> None:
        """Unlock sets the closing status and schedules teardown."""
        gate._unlock("logged X")
        assert "unlocking" in gate._vars.status.get()


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
