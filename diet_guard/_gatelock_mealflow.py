"""Submit/record/meal-building flow and dashboard for the MealGate gate.

Split out of :mod:`._gatelock` to keep that module under the repo's 500-line
limit.  ``_GateMealFlow`` extends
:class:`~python_pkg.diet_guard._gatelock_nutrition._GateNutrition` with the
submit/lookup/log flow for single foods and multi-item meals, the per-slot
input reset, and the running calorie/macro dashboard.
"""

from __future__ import annotations

import contextlib
import tkinter as tk
from typing import TYPE_CHECKING

from python_pkg.diet_guard._budget import BudgetError, daily_budget, protein_target_g
from python_pkg.diet_guard._foodbank import remember_food, remember_meal
from python_pkg.diet_guard._gatelock_nutrition import _GateNutrition
from python_pkg.diet_guard._gatelock_ui import ERR, FG, UNIT_GRAMS
from python_pkg.diet_guard._meal import MealItem, meal_total
from python_pkg.diet_guard._resolve import lookup_candidates
from python_pkg.diet_guard._slots import slot_label
from python_pkg.diet_guard._state import (
    entry_kcal,
    log_meal,
    today_entries,
    today_total_kcal,
    today_total_macros,
)

if TYPE_CHECKING:
    from python_pkg.diet_guard._estimator import Nutrition

# How long the "unlocking..." confirmation lingers before the window tears down.
_UNLOCK_DELAY_MS = 1200
# How many recent meals the dashboard lists.
_DASHBOARD_ROWS = 5
# ISO timestamp "YYYY-MM-DDTHH:MM:SS": HH:MM is characters 11..16.
_TIME_SLICE = slice(11, 16)
# Width a meal description is truncated to in the dashboard.
_DASH_DESC_WIDTH = 22
# Fallback name for a multi-item meal when the user leaves the name field blank.
_DEFAULT_MEAL_NAME = "meal"


class _GateMealFlow(_GateNutrition):
    """Submit/lookup/log flow for single foods and multi-item meals."""

    # -- slot walk (meal-in-progress reset) ----------------------------------

    def _clear_food_inputs(self) -> None:
        """Empty the food fields, picker, preview, and basis (keeps any meal)."""
        self._set_desc("")
        self._widgets.amount_entry.delete(0, tk.END)
        self._vars.unit.set(UNIT_GRAMS)
        self._relabel_basis()
        self._reset_per_default()
        for entry in self._macro_entries():
            entry.delete(0, tk.END)
        self._widgets.suggestion_box.delete(0, tk.END)
        self._state.suggestions = []
        self._state.source = "manual"
        self._state.last_reference = None
        self._vars.preview.set("")
        self._refresh_projection()

    def _clear_inputs(self) -> None:
        """Empty the food fields and discard any in-progress meal (new slot)."""
        self._clear_food_inputs()
        self._state.meal_items = []
        self._widgets.meal_name_entry.delete(0, tk.END)
        self._vars.meal_summary.set("")

    # -- behaviour ------------------------------------------------------------

    def _set_status(self, text: str, *, error: bool = False) -> None:
        """Update the status line, red for errors."""
        self._vars.status.set(text)
        self._widgets.status_label.config(fg=ERR if error else FG)

    def _on_return(self, _event: tk.Event[tk.Misc]) -> None:
        """Handle the Enter key in any entry field."""
        self._on_submit()

    def _on_submit(self) -> None:
        """Validate, then look up, or log -- as a single food or a summed meal.

        With a meal in progress, an empty form finalizes the accumulated items,
        and a completed form adds itself as the meal's last item before logging.
        With no meal in progress this is the original single-food path.
        """
        description = self._get_desc()
        if not description:
            if self._state.meal_items:
                self._log_meal()
                return
            self._set_status("Type what you ate first.", error=True)
            self._widgets.desc_text.focus_set()
            return

        values = self._macro_values()
        if values is None:
            self._set_status("Macros must be numbers.", error=True)
            self._widgets.macros.kcal.focus_set()
            return

        if values[0] is None:
            self._begin_lookup(description)
            return
        nutrition = self._current_nutrition()
        if nutrition is None:
            self._set_status("Enter the calories, then submit.", error=True)
            self._widgets.macros.kcal.focus_set()
            return
        if self._state.meal_items:
            self._state.meal_items.append(MealItem(description, nutrition))
            self._log_meal()
            return
        self._record(description, nutrition)

    def _begin_lookup(self, description: str) -> None:
        """Step 1: look the food up, fill the label fields, offer alternatives.

        Nothing is logged here -- the user must see and confirm the filled
        values (a second submit) before they are recorded.  The food is looked
        up at its natural basis (per 100 g / serving); the amount eaten scales
        it, so the lookup never bakes in a portion.
        """
        self._set_status("looking up…")
        self.root.update_idletasks()
        candidates = lookup_candidates(description)
        if not candidates:
            self._set_status(
                "Couldn't look that up. Enter the calories yourself, then submit.",
                error=True,
            )
            self._widgets.macros.kcal.focus_set()
            return
        self._show_candidates(candidates)
        self._apply_reference(candidates[0][1])
        source = candidates[0][1].source
        tail = (
            "Review, or pick another below, then submit to log."
            if len(candidates) > 1
            else "Review the values, then submit to log."
        )
        self._set_status(f"Filled from {source}. {tail}")

    def _record(self, description: str, nutrition: Nutrition) -> None:
        """Log and bank a single food for the current slot, then advance."""
        log_meal(description, nutrition, self._slot_for_log())
        remember_food(description, nutrition)
        self._finish_slot(f"{nutrition.kcal:g} kcal ({nutrition.source})")

    def _meal_name(self) -> str:
        """Return the trimmed meal name the user typed (empty if none)."""
        return self._widgets.meal_name_entry.get().strip()

    def _refresh_meal_summary(self) -> None:
        """Update the running "meal so far" line from the accumulated items."""
        if not self._state.meal_items:
            self._vars.meal_summary.set("")
            return
        total = meal_total(self._state.meal_items)
        names = ", ".join(item.name for item in self._state.meal_items)
        self._vars.meal_summary.set(
            f"Meal so far ({len(self._state.meal_items)}): {names}  →  "
            f"{total.kcal:g} kcal · P{total.protein_g:g} "
            f"C{total.carbs_g:g} F{total.fat_g:g}",
        )

    def _on_add_item(self) -> None:
        """Add the current form as one component of a multi-part meal.

        Requires a name and resolved calories (a blank calorie field triggers a
        lookup first, exactly like submitting).  On success the item is appended
        to the meal-in-progress, the running total updates, and the food fields
        clear for the next item while the meal name is kept.
        """
        description = self._get_desc()
        if not description:
            self._set_status("Type the item first, then add it.", error=True)
            self._widgets.desc_text.focus_set()
            return
        values = self._macro_values()
        if values is None:
            self._set_status("Macros must be numbers.", error=True)
            self._widgets.macros.kcal.focus_set()
            return
        if values[0] is None:
            self._begin_lookup(description)
            return
        nutrition = self._current_nutrition()
        if nutrition is None:
            self._set_status("Enter the calories, then add the item.", error=True)
            self._widgets.macros.kcal.focus_set()
            return
        self._state.meal_items.append(MealItem(description, nutrition))
        self._refresh_meal_summary()
        self._clear_food_inputs()
        self._set_status(f"Added {description}. Add another, or Log & Continue.")
        self._widgets.desc_text.focus_set()

    def _slot_for_log(self) -> int | None:
        """Return the slot to tag a log with -- None in demo (satisfies no slot).

        A synthetic demo slot must never satisfy a real checkpoint, so demo logs
        are slot-less: they still bank the food and update the dashboard, but do
        not silently stop the production gate from firing.
        """
        return None if self.demo_mode else self._pending[0]

    def _log_meal(self) -> None:
        """Log the accumulated multi-item meal for the current slot and advance.

        Each component and the summed composite are banked (see
        :func:`python_pkg.diet_guard._foodbank.remember_meal`), and the slot is
        satisfied by the summed total under the meal's name.
        """
        name = self._meal_name() or _DEFAULT_MEAL_NAME
        count = len(self._state.meal_items)
        total = remember_meal(name, list(self._state.meal_items))
        log_meal(name, total, self._slot_for_log())
        self._state.meal_items = []
        self._finish_slot(f"{name}: {total.kcal:g} kcal ({count} items)")

    def _finish_slot(self, summary: str) -> None:
        """Advance past the current slot after something was logged for it.

        Args:
            summary: A short description of what was logged (calories/source, or
                the meal name and item count), shown in the confirmation line.
        """
        slot = self._pending[0]
        self._pending.pop(0)
        self._refresh_dashboard()
        logged = f"Logged {slot_label(slot)}: {summary}"
        if not self._pending:
            self._unlock(logged)
            return
        self._clear_inputs()
        self._refresh_slot_header()
        self._set_status(f"{logged} — next meal, please.")
        self._widgets.desc_text.focus_set()

    def _unlock(self, logged: str) -> None:
        """Confirm the final log and tear the window down.

        Teardown is scheduled *before* the budget is looked up, so a broken
        budget seal (which raises) can never re-trap the user at unlock time.
        """
        self._set_status(f"{logged} — all meals logged, unlocking…")
        self.root.after(_UNLOCK_DELAY_MS, self.close)

    # -- dashboard --------------------------------------------------------------

    def _refresh_dashboard(self) -> None:
        """Recompute the prominent calorie headline and the detail panel."""
        self._vars.cal_headline.set(self._cal_headline_text())
        self._vars.dashboard.set(self._dashboard_text())

    def _cal_headline_text(self) -> str:
        """Return the big calories-today line: consumed, target, and remaining."""
        consumed = today_total_kcal()
        try:
            budget = daily_budget()
        except (BudgetError, OSError):
            return f"{consumed:g} kcal today"
        return (
            f"{consumed:g} / {budget:g} kcal   ·   {round(budget - consumed, 1):g} left"
        )

    def _dashboard_text(self) -> str:
        """Build the detail panel: recent meals, then macros and protein."""
        lines = ["── Today ───────────────────────────────"]
        entries = today_entries()
        if entries:
            for entry in entries[-_DASHBOARD_ROWS:]:
                clock = str(entry.get("time", ""))[_TIME_SLICE]
                desc = str(entry.get("desc", "?"))[:_DASH_DESC_WIDTH]
                lines.append(
                    f"  {clock:>5}  {desc:<{_DASH_DESC_WIDTH}}  "
                    f"{entry_kcal(entry):>5.0f} kcal",
                )
        else:
            lines.append("  (nothing logged yet today)")
        protein, carbs, fat = today_total_macros()
        lines.append(f"  macros so far:  P{protein:g}  C{carbs:g}  F{fat:g}  g")
        target = protein_target_g()
        if target is not None:
            left = round(target - protein, 1)
            lines.append(f"  protein {protein:g} / {target:g} g  ({left:g} g left)")
        return "\n".join(lines)

    def on_callback_error(self) -> None:
        """Surface an unexpected callback error without dropping the grab."""
        self._set_status(
            "Something went wrong. Enter the calories, then submit again.",
            error=True,
        )
        with contextlib.suppress(tk.TclError):
            self._widgets.macros.kcal.focus_set()
