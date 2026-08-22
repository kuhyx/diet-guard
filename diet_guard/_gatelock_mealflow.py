"""Submit/record flow for the MealGate gate.

Split out of :mod:`._gatelock` to keep that module under the repo's 250-line
limit.  ``_GateMealFlow`` extends
:class:`~diet_guard._gatelock_dashboard._GateDashboard` (itself over
:class:`~diet_guard._gatelock_nutrition._GateNutrition`) with the
submit/lookup/log flow and the per-slot input reset.  The read-only
calorie/macro dashboard it calls into lives in :mod:`._gatelock_dashboard`.
"""

from __future__ import annotations

import contextlib
import tkinter as tk
from typing import TYPE_CHECKING

from diet_guard._budget import BudgetError, daily_budget
from diet_guard._budget_derived import protein_target_g
from diet_guard._foodbank import remember_food
from diet_guard._gatelock_delivery import _PullFlows
from diet_guard._gatelock_ui import ERR, FG, UNIT_GRAMS
from diet_guard._resolve import lookup_candidates
from diet_guard._slots import slot_label
from diet_guard._state import entry_kcal, log_meal
from diet_guard._state_today import (
    today_entries,
    today_total_kcal,
    today_total_macros,
)

if TYPE_CHECKING:
    from diet_guard._estimator import Nutrition

# How long the "unlocking..." confirmation lingers before the window tears down.
_UNLOCK_DELAY_MS = 1200

# How many recent meals the dashboard lists.
_DASHBOARD_ROWS = 5
# ISO timestamp "YYYY-MM-DDTHH:MM:SS": HH:MM is characters 11..16.
_TIME_SLICE = slice(11, 16)
# Width a meal description is truncated to in the dashboard.
_DASH_DESC_WIDTH = 22


class _GateMealFlow(_PullFlows):
    """Submit/lookup/log flow for a logged food."""

    # -- slot walk ------------------------------------------------------------

    def _clear_inputs(self) -> None:
        """Empty the food fields, picker, preview, and basis for a new slot."""
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

    # -- behaviour ------------------------------------------------------------

    def _set_status(self, text: str, *, error: bool = False) -> None:
        """Update the status line, red for errors."""
        self._vars.status.set(text)
        self._widgets.status_label.config(fg=ERR if error else FG)

    def _on_return(self, _event: tk.Event[tk.Misc]) -> None:
        """Handle the Enter key in any entry field."""
        self._on_submit()

    def _on_submit(self) -> None:
        """Validate, then look the food up, or log it."""
        description = self._get_desc()
        if not description:
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

    def _slot_for_log(self) -> int | None:
        """Return the slot to tag a log with -- None in demo (satisfies no slot).

        A synthetic demo slot must never satisfy a real checkpoint, so demo logs
        are slot-less: they still bank the food and update the dashboard, but do
        not silently stop the production gate from firing.
        """
        return None if self.demo_mode else self._pending[0]

    def _finish_slot(self, summary: str) -> None:
        """Advance past the current slot after something was logged for it.

        Args:
            summary: A short description of what was logged (calories and
                source), shown in the confirmation line.
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
        # A catering delivery is offered one dish at a time, so the queue has
        # to survive the submit that consumed the previous dish: without this
        # the "(N more to go)" the user was just promised strands those N, and
        # re-reaching them costs a fresh network walk per dish. Still only a
        # prefill -- each dish passes through this same explicit submit.
        if self._delivery_pending:
            self._prefill_next_dish(logged)
            return
        self._set_status(f"{logged} — next meal, please.")
        self._widgets.desc_text.focus_set()

    def _unlock(self, logged: str) -> None:
        """Confirm the final log and tear the window down.

        Teardown is scheduled *before* the budget is looked up, so a corrupt
        budget file (which raises) can never re-trap the user at unlock time.
        """
        # A 5-meal plan against 4 slots leaves a dish queued when the last slot
        # is satisfied (``_kuchnia_spread`` doubles up the earliest slots), so
        # say what was not offered rather than dropping it silently. Purely
        # informational: the dishes are already banked, and the lock is over.
        left = len(self._delivery_pending)
        if left:
            noun = "dish" if left == 1 else "dishes"
            logged = f"{logged} ({left} more {noun} delivered; log with 'ate')"
        self._set_status(f"{logged} — all meals logged, unlocking…")
        self.root.after(_UNLOCK_DELAY_MS, self.close)

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
