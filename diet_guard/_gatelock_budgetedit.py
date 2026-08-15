"""Budget editing on the gate's History tab.

Split out of :mod:`._gatelock_calendar` to keep every gate module under the
repo's 250-line limit.  ``_GateBudgetEdit`` sits between
:class:`~diet_guard._gatelock_mealflow._GateMealFlow` and
:class:`~diet_guard._gatelock_calendar._GateCalendar` in the mixin chain and
owns the one place either device edits the daily budget.

The budget is a plain, freely-editable synced file -- no seal, no signing.
That is deliberate (it replaced a ``chattr +i`` mechanism so the value is
editable from either device); do not reintroduce the seal here.
"""

from __future__ import annotations

import abc
import contextlib
import tkinter as tk
from typing import TYPE_CHECKING

from diet_guard._budget import BudgetError, budget_weight, write_budget
from diet_guard._gatelock_mealflow import _GateMealFlow
from diet_guard._gatelock_ui import ERR, FG

if TYPE_CHECKING:
    from diet_guard._gatelock_calendar_types import CalendarVars, CalendarWidgets

__all__ = ["_GateBudgetEdit"]


class _GateBudgetEdit(_GateMealFlow):
    """The History tab's budget row: display, edit toggle, validate, persist.

    The calendar state below is *declared* here and **created** by
    :class:`~diet_guard._gatelock_calendar._GateCalendar`, further down the
    mixin chain: this half only reads and writes the budget row, while the
    other owns the tab's construction and refresh. Declaring the attributes
    keeps that split checkable rather than implicit.
    """

    _cal_vars: CalendarVars
    _cal_surfaces: list[CalendarWidgets]
    _cal_editing_budget: bool

    @abc.abstractmethod
    def _refresh_calendar(self) -> None:
        """Repaint the History tab; implemented by ``_GateCalendar``."""

    def _set_budget_entry_state(self, state: str) -> None:
        """Lock or unlock the budget entry on every monitor."""
        for surface in self._cal_surfaces:
            with contextlib.suppress(tk.TclError):
                surface.budget_entry.config(state=state)

    def _set_budget_button_text(self, text: str) -> None:
        """Relabel the budget edit/save button on every monitor."""
        for surface in self._cal_surfaces:
            with contextlib.suppress(tk.TclError):
                surface.budget_edit_button.config(text=text)

    def _set_budget_status(self, text: str, *, error: bool) -> None:
        """Update the budget-edit status line, red for errors."""
        self._cal_vars.budget_status.set(text)
        colour = ERR if error else FG
        for surface in self._cal_surfaces:
            with contextlib.suppress(tk.TclError):
                surface.budget_status_label.config(fg=colour)

    def _on_edit_or_save_budget(self) -> None:
        """Toggle the budget row between read-only display and editing.

        First click: unlock the entry for typing and relabel the button
        "Save" -- nothing is persisted yet.  Second click: validate and
        persist; on success, lock the entry back to read-only and relabel
        the button "Edit".  A validation failure leaves editing open so the
        user can correct the value instead of silently discarding it.
        """
        if not self._cal_editing_budget:
            self._cal_editing_budget = True
            self._set_budget_entry_state("normal")
            self._set_budget_button_text("Save")
            self._set_budget_status("", error=False)
            return
        if not self._save_budget_entry():
            return
        self._cal_editing_budget = False
        self._set_budget_button_text("Edit")
        self._refresh_calendar()
        self._refresh_dashboard()
        self._refresh_projection()

    def _save_budget_entry(self) -> bool:
        """Validate and persist the entry's current text.

        Preserves any body weight already stored alongside the budget (used
        to derive the protein target) -- a bare ``write_budget(value)`` would
        silently drop it, since the file holds one record, not a diff.

        Returns:
            Whether the value was valid and persisted.
        """
        raw = self._cal_vars.budget.get().strip()
        try:
            value = int(raw)
        except ValueError:
            self._set_budget_status("Enter a whole number of kcal.", error=True)
            return False
        if value <= 0:
            self._set_budget_status("Budget must be a positive number.", error=True)
            return False
        try:
            weight = budget_weight()
        except BudgetError:
            weight = None
        write_budget(value, weight_kg=weight)
        self._set_budget_status("Saved.", error=False)
        return True
