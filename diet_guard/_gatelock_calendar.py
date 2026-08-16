"""History tab: budget-adherence calendar, streaks, YTD tally.

Split out of :mod:`._gatelock` (and kept out of :mod:`._gatelock_ui`) to keep
every gate module under the repo's 250-line limit.  ``_GateCalendar`` extends
:class:`~diet_guard._gatelock_budgetedit._GateBudgetEdit` with a second
``ttk.Notebook`` tab: the calendar/streak/tally view built from
:mod:`diet_guard._calendar_view`'s pure grid math.  The budget-edit half of
the tab -- the one place either device edits the freely-editable, synced daily
budget -- lives in :mod:`._gatelock_budgetedit`.

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
from typing import TYPE_CHECKING

from diet_guard._budget import (
    BudgetFileCorruptError,
    BudgetNotInitializedError,
    current_schedule,
    daily_budget,
)
from diet_guard._calendar_view import (
    CalendarCell,
    averages_text,
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
from diet_guard._gatelock_layout import build_layout
from diet_guard._gatelock_scheduleedit import _GateScheduleEdit
from diet_guard._meal_schedule_store import (
    current_schedule as current_meal_schedule,
)
from diet_guard._state import load_log, now_local

if TYPE_CHECKING:
    from diet_guard._gatelock_ui import (
        GateCallbacks,
        GateWidgets,
    )

__all__ = [
    "CalendarCallbacks",
    "CalendarVars",
    "CalendarWidgets",
    "_GateCalendar",
    "build_calendar_frame",
    "make_calendar_vars",
]


class _GateCalendar(_GateScheduleEdit):
    """History tab: calendar, streaks, YTD tally, and budget editing."""

    _cal_vars: CalendarVars
    _cal_widgets: CalendarWidgets
    _cal_surfaces: list[CalendarWidgets]
    _cal_year: int
    _cal_month: int
    _cal_editing_budget: bool
    _cal_editing_schedule: bool
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
        self._cal_editing_schedule = False
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
            on_edit_or_save_schedule=self._on_edit_or_save_schedule,
        )
        cal_widgets = build_calendar_frame(notebook, self._cal_vars, cal_callbacks)
        notebook.add(cal_widgets.frame, text="History")
        # Ctrl+Tab / Ctrl+PageUp / Ctrl+PageDown and Alt+mnemonic tab switching
        # all live in toplevel bindings that ttk only installs on request. The
        # notebook is in the focus ring and Left/Right work once it holds focus,
        # but without this the idioms a user actually reaches for are dead.
        notebook.enable_traversal()
        self._cal_surfaces.append(cal_widgets)
        self._cal_widgets = cal_widgets
        return widgets

    # -- refresh --------------------------------------------------------------

    def _refresh_calendar(self) -> None:
        """Recompute the grid, streaks, YTD tally, averages, and budget field.

        Each past day is judged against the budget that applied *then*
        (:mod:`diet_guard._budget_history`), so changing the budget today
        leaves the grid, the streaks, and the tally for earlier days alone.

        A budget that was never set defaults to
        :data:`_DEFAULT_BUDGET_KCAL`, matching the phone app, so the tab is
        meaningful from a fresh install with no setup ritual.  A genuinely
        corrupt budget file is a real problem, not just "unset" -- that
        still degrades to a neutral grid and an error message, instead of
        raising through the tab and crashing (or failing open) the lock.
        Degradation is deliberately asymmetric: an unreadable *history*
        silently falls back to today's scalar budget (the pre-history
        behaviour), because that is a display nicety, whereas an unreadable
        budget is the number itself.
        """
        log = load_log()
        try:
            budget: int | None = daily_budget()
        except BudgetNotInitializedError:
            budget = _DEFAULT_BUDGET_KCAL
        except BudgetFileCorruptError:
            budget = None
        schedule = current_schedule(default=budget) if budget is not None else None
        if schedule is None:
            self._render_month(None)
            self._cal_vars.streaks.set("Budget file is corrupt -- fix it below.")
            self._cal_vars.ytd.set("")
            self._cal_vars.averages.set("")
        else:
            status_map_ = status_map(log, schedule=schedule)
            self._render_month(status_map_)
            self._cal_vars.streaks.set(streaks_text(status_map_))
            self._cal_vars.ytd.set(ytd_text(status_map_))
            self._cal_vars.averages.set(averages_text(log, schedule=schedule))
        if not self._cal_editing_budget:
            self._refresh_budget_field(budget)
        if not self._cal_editing_schedule:
            self._show_schedule(current_meal_schedule())

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
