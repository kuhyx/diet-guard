"""Tests for the History tab (_GateCalendar): notebook wiring, no-bypass
regression, budget-degrade, month navigation, and budget editing."""

from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _budget
from diet_guard._budget import budget_weight, daily_budget, write_budget
from diet_guard._state import log_meal
from diet_guard.tests.conftest import _nutrition

if TYPE_CHECKING:
    from diet_guard._gatelock import MealGate


class TestNotebookWiring:
    """The gate builds a two-tab notebook without breaking construction."""

    def test_builds_a_notebook_with_both_tabs(self, gate: MealGate) -> None:
        labels = [text for _child, text in gate._notebook.tabs]
        assert labels == ["Log Meal", "History"]

    def test_calendar_state_starts_on_the_current_month(self, gate: MealGate) -> None:
        assert 1 <= gate._cal_month <= 12
        assert gate._cal_year >= 2024


class TestNoBypassRegression:
    """Switching to the History tab must never affect the lock's dismissal."""

    def test_switching_to_the_history_tab_does_not_touch_pending_or_close(
        self,
        gate: MealGate,
    ) -> None:
        pending_before = list(gate._pending)
        history_frame = gate._cal_widgets.frame
        with patch.object(gate, "close") as mock_close:
            gate._notebook.select(history_frame)
        assert gate._notebook.select() == 1
        assert gate._pending == pending_before
        mock_close.assert_not_called()

    def test_switching_back_to_the_log_meal_tab_is_also_a_no_op(
        self,
        gate: MealGate,
    ) -> None:
        pending_before = list(gate._pending)
        with patch.object(gate, "close") as mock_close:
            gate._notebook.select(gate._cal_widgets.frame)
            gate._notebook.select(gate._widgets.frame)
        assert gate._notebook.select() == 0
        assert gate._pending == pending_before
        mock_close.assert_not_called()


class TestBudgetDefaultAndDegradation:
    """No budget ever set defaults to 2200; a corrupt file still degrades."""

    def test_no_budget_set_computes_real_streaks_against_the_default(
        self,
        gate: MealGate,
    ) -> None:
        gate._refresh_calendar()
        assert "Logging streak" in gate._cal_vars.streaks.get()
        assert "This year" in gate._cal_vars.ytd.get()

    def test_no_budget_set_shows_2200_in_the_entry(self, gate: MealGate) -> None:
        gate._refresh_calendar()
        assert gate._cal_widgets.budget_entry.get() == "2200"

    def test_entry_starts_read_only(self, gate: MealGate) -> None:
        assert gate._cal_widgets.budget_entry.configured.get("state") == "readonly"

    def test_edit_button_starts_labelled_edit(self, gate: MealGate) -> None:
        assert gate._cal_widgets.budget_edit_button.configured.get("text") == "Edit"

    def test_no_budget_set_still_renders_every_grid_cell(
        self,
        gate: MealGate,
    ) -> None:
        gate._refresh_calendar()
        for cell in gate._cal_widgets.day_cells:
            assert "bg" in cell.configured

    def test_a_real_budget_set_shows_in_the_entry(self, gate: MealGate) -> None:
        write_budget(1800)
        log_meal("oatmeal", _nutrition(kcal=300), None)
        gate._refresh_calendar()
        assert gate._cal_widgets.budget_entry.get() == "1800"
        assert "Logging streak" in gate._cal_vars.streaks.get()

    def test_a_corrupt_budget_file_degrades_with_an_error_message(
        self,
        gate: MealGate,
    ) -> None:
        _budget.BUDGET_FILE.write_text("not json")
        gate._refresh_calendar()
        assert "corrupt" in gate._cal_vars.streaks.get()
        assert gate._cal_vars.ytd.get() == ""


class TestMonthNavigation:
    """Prev/next steps the displayed month, wrapping the year correctly."""

    def test_prev_month_steps_back_within_the_year(self, gate: MealGate) -> None:
        gate._cal_year, gate._cal_month = 2026, 7
        gate._on_prev_month()
        assert (gate._cal_year, gate._cal_month) == (2026, 6)

    def test_prev_month_wraps_the_year_at_january(self, gate: MealGate) -> None:
        gate._cal_year, gate._cal_month = 2026, 1
        gate._on_prev_month()
        assert (gate._cal_year, gate._cal_month) == (2025, 12)

    def test_next_month_steps_forward_within_the_year(self, gate: MealGate) -> None:
        gate._cal_year, gate._cal_month = 2026, 6
        gate._on_next_month()
        assert (gate._cal_year, gate._cal_month) == (2026, 7)

    def test_next_month_wraps_the_year_at_december(self, gate: MealGate) -> None:
        gate._cal_year, gate._cal_month = 2026, 12
        gate._on_next_month()
        assert (gate._cal_year, gate._cal_month) == (2027, 1)


class TestBudgetEditToggle:
    """Edit/Save toggle: first click unlocks, second click validates+saves."""

    def _type(self, gate: MealGate, value: str) -> None:
        """Replace the budget entry's text (as if the user retyped it)."""
        gate._cal_widgets.budget_entry.delete(0, "end")
        gate._cal_widgets.budget_entry.insert(0, value)

    def test_first_click_unlocks_editing_without_persisting(
        self,
        gate: MealGate,
    ) -> None:
        gate._on_edit_or_save_budget()
        assert gate._cal_editing_budget is True
        assert gate._cal_widgets.budget_edit_button.configured.get("text") == "Save"
        assert gate._cal_widgets.budget_entry.configured.get("state") == "normal"

    def test_second_click_with_non_numeric_input_stays_in_edit_mode(
        self,
        gate: MealGate,
    ) -> None:
        gate._on_edit_or_save_budget()
        self._type(gate, "not a number")
        gate._on_edit_or_save_budget()
        assert gate._cal_editing_budget is True
        assert "whole number" in gate._cal_vars.budget_status.get()
        assert gate._cal_widgets.budget_edit_button.configured.get("text") == "Save"

    def test_second_click_with_zero_is_rejected_and_stays_in_edit_mode(
        self,
        gate: MealGate,
    ) -> None:
        gate._on_edit_or_save_budget()
        self._type(gate, "0")
        gate._on_edit_or_save_budget()
        assert gate._cal_editing_budget is True
        assert "positive" in gate._cal_vars.budget_status.get()

    def test_second_click_with_negative_is_rejected(self, gate: MealGate) -> None:
        gate._on_edit_or_save_budget()
        self._type(gate, "-500")
        gate._on_edit_or_save_budget()
        assert "positive" in gate._cal_vars.budget_status.get()

    def test_second_click_with_a_valid_value_saves_and_exits_edit_mode(
        self,
        gate: MealGate,
    ) -> None:
        gate._on_edit_or_save_budget()
        self._type(gate, "1900")
        gate._on_edit_or_save_budget()
        assert gate._cal_editing_budget is False
        assert gate._cal_vars.budget_status.get() == "Saved."
        assert gate._cal_widgets.budget_edit_button.configured.get("text") == "Edit"
        assert gate._cal_widgets.budget_entry.configured.get("state") == "readonly"
        assert daily_budget() == 1900

    def test_saving_preserves_a_previously_stored_weight(
        self,
        gate: MealGate,
    ) -> None:
        write_budget(2000, weight_kg=80)
        gate._on_edit_or_save_budget()
        self._type(gate, "2100")
        gate._on_edit_or_save_budget()
        assert budget_weight() == 80

    def test_saving_refreshes_the_dashboard_headline(self, gate: MealGate) -> None:
        gate._on_edit_or_save_budget()
        self._type(gate, "1700")
        gate._on_edit_or_save_budget()
        assert "1700" in gate._vars.cal_headline.get()

    def test_navigating_months_mid_edit_does_not_overwrite_the_typed_value(
        self,
        gate: MealGate,
    ) -> None:
        gate._on_edit_or_save_budget()
        self._type(gate, "1234")
        gate._on_prev_month()
        assert gate._cal_widgets.budget_entry.get() == "1234"
