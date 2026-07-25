"""History tab: budget-adherence calendar, streaks, YTD tally, budget edit.

Split out of :mod:`._gatelock` (and kept out of :mod:`._gatelock_ui`) to keep
every gate module under the repo's 500-line limit.  ``_GateCalendar`` extends
:class:`~diet_guard._gatelock_mealflow._GateMealFlow` with a second
``ttk.Notebook`` tab: the calendar/streak/tally view built from
:mod:`diet_guard._calendar_view`'s pure grid math, plus a budget-edit field
writing through :func:`diet_guard._budget.write_budget` -- the one place
either device edits the now freely-editable, synced daily budget.

The month-grid math itself lives in :mod:`diet_guard._calendar_view` (no Tk
dependency), so the boundary cases (varying month length/first weekday,
every :class:`~diet_guard._daystatus.DayStatus`, future days, no budget set)
are unit-tested directly without a fake Tk in the loop.
"""

from __future__ import annotations

import calendar
import contextlib
import tkinter as tk
from tkinter import ttk

from diet_guard._budget import (
    BudgetError,
    BudgetFileCorruptError,
    BudgetNotInitializedError,
    budget_weight,
    daily_budget,
    write_budget,
)
from diet_guard._calendar_view import (
    CalendarCell,
    build_month_cells,
    cell_style,
    streaks_text,
    ytd_text,
)
from diet_guard._daystatus import DayStatus, status_map
from diet_guard._gatelock_calendar_ui import (
    _DECEMBER,
    _DEFAULT_BUDGET_KCAL,
    _JANUARY,
    _MONTH_AFTER_DECEMBER,
    CalendarCallbacks,
    CalendarVars,
    CalendarWidgets,
    _style_notebook,
    build_calendar_frame,
    make_calendar_vars,
)
from diet_guard._gatelock_mealflow import _GateMealFlow
from diet_guard._gatelock_ui import (
    ERR,
    FG,
    GateCallbacks,
    GateWidgets,
    build_layout,
)
from diet_guard._state import load_log, now_local

__all__ = [
    "CalendarCallbacks",
    "CalendarVars",
    "CalendarWidgets",
    "_GateCalendar",
    "build_calendar_frame",
    "make_calendar_vars",
]


class _GateCalendar(_GateMealFlow):
    """History tab: calendar, streaks, YTD tally, and budget editing."""

    _cal_vars: CalendarVars
    _cal_widgets: CalendarWidgets
    _cal_surfaces: list[CalendarWidgets]
    _cal_year: int
    _cal_month: int
    _cal_editing_budget: bool
    _notebook: ttk.Notebook

    def _build_tabs(self, parent: tk.Misc, callbacks: GateCallbacks) -> GateWidgets:
        """Build one monitor's notebook, wire both tabs, return its meal widgets.

        Called once per live output since gatelock v0.2.0. Every copy shares
        one set of ``GateVars``, so the meal form stays in step across
        monitors; the calendar tab is read-only apart from the budget field,
        which is likewise variable-backed.

        The History tab's own widgets are stashed per surface so the refresh
        pass can repaint every monitor's grid.
        """
        today = now_local().date()
        self._cal_year = today.year
        self._cal_month = today.month
        self._cal_editing_budget = False
        _style_notebook(parent)
        notebook = ttk.Notebook(parent)
        notebook.place(relx=0, rely=0, relwidth=1, relheight=1)
        self._notebook = notebook

        widgets = build_layout(
            notebook, self._vars, callbacks, demo_mode=self.demo_mode
        )
        notebook.add(widgets.frame, text="Log Meal")

        cal_callbacks = CalendarCallbacks(
            on_prev_month=self._on_prev_month,
            on_next_month=self._on_next_month,
            on_edit_or_save_budget=self._on_edit_or_save_budget,
        )
        cal_widgets = build_calendar_frame(notebook, self._cal_vars, cal_callbacks)
        notebook.add(cal_widgets.frame, text="History")
        self._cal_surfaces.append(cal_widgets)
        self._cal_widgets = cal_widgets
        return widgets

    # -- refresh --------------------------------------------------------------

    def _refresh_calendar(self) -> None:
        """Recompute the calendar grid, streaks, YTD tally, and budget field.

        A budget that was never set defaults to
        :data:`_DEFAULT_BUDGET_KCAL`, matching the phone app, so the tab is
        meaningful from a fresh install with no setup ritual.  A genuinely
        corrupt budget file is a real problem, not just "unset" -- that
        still degrades to a neutral grid and an error message, instead of
        raising through the tab and crashing (or failing open) the lock.
        """
        log = load_log()
        try:
            budget: int | None = daily_budget()
        except BudgetNotInitializedError:
            budget = _DEFAULT_BUDGET_KCAL
        except BudgetFileCorruptError:
            budget = None
        status_map_ = status_map(log, budget=budget) if budget is not None else None
        self._render_month(status_map_)
        if status_map_ is None:
            self._cal_vars.streaks.set("Budget file is corrupt -- fix it below.")
            self._cal_vars.ytd.set("")
        else:
            self._cal_vars.streaks.set(streaks_text(status_map_))
            self._cal_vars.ytd.set(ytd_text(status_map_))
        if not self._cal_editing_budget:
            self._refresh_budget_field(budget)

    def _render_month(self, status_map_: dict[str, DayStatus] | None) -> None:
        """Redraw the day-cell grid and month label for the displayed month."""
        weeks = build_month_cells(self._cal_year, self._cal_month, status_map_)
        self._cal_vars.month_label.set(
            f"{calendar.month_name[self._cal_month]} {self._cal_year}",
        )
        for surface in self._cal_surfaces:
            for index, cell_widget in enumerate(surface.day_cells):
                row, col = divmod(index, 7)
                spec = weeks[row][col] if row < len(weeks) else CalendarCell(None, None)
                bg, fg, outline = cell_style(spec.status)
                with contextlib.suppress(tk.TclError):
                    cell_widget.config(
                        text=str(spec.day) if spec.day else "",
                        bg=bg,
                        fg=fg,
                        highlightbackground=outline,
                    )

    def _refresh_budget_field(self, budget: int | None) -> None:
        """Show ``budget`` in the (read-only) entry, or leave it blank if unset.

        The text goes through the shared variable rather than the widget,
        which sidesteps the old dance of flipping to "normal" to mutate it:
        a ``readonly`` Entry rejects ``.insert``/``.delete`` but still
        follows its ``textvariable``.
        """
        self._cal_vars.budget.set("" if budget is None else str(budget))
        self._set_budget_entry_state("readonly")

    # -- month navigation -------------------------------------------------------

    def _on_prev_month(self) -> None:
        """Step the displayed month back one, wrapping the year at January."""
        self._cal_month -= 1
        if self._cal_month < _JANUARY:
            self._cal_month = _DECEMBER
            self._cal_year -= 1
        self._refresh_calendar()

    def _on_next_month(self) -> None:
        """Step the displayed month forward one, wrapping the year at December."""
        self._cal_month += 1
        if self._cal_month == _MONTH_AFTER_DECEMBER:
            self._cal_month = _JANUARY
            self._cal_year += 1
        self._refresh_calendar()

    # -- budget editing -----------------------------------------------------

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
