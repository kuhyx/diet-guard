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
from dataclasses import dataclass
import tkinter as tk
from tkinter import ttk
from typing import TYPE_CHECKING

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
from diet_guard._gatelock_mealflow import _GateMealFlow
from diet_guard._gatelock_ui import (
    BG,
    ERR,
    FG,
    GateCallbacks,
    GateWidgets,
    build_layout,
)
from diet_guard._state import load_log, now_local

if TYPE_CHECKING:
    from collections.abc import Callable

# Palette additions specific to the calendar (BG/FG/ERR come from
# _gatelock_ui's public exports; the rest are private to that module, so
# equivalents are defined locally rather than reaching across the boundary).
_MUTED = "#9a9a9a"
_FIELD_BG = "#2a2a2a"
_ACCENT = "#00ff88"

# calendar.monthcalendar never returns more than 6 weeks for any month.
_MONTH_ROWS = 6
_WEEKDAY_LABELS = ("Mo", "Tu", "We", "Th", "Fr", "Sa", "Su")
_JANUARY = 1
_DECEMBER = 12
_MONTH_AFTER_DECEMBER = 13

# Shown (and classified against) before any budget has ever been set --
# mirrors the phone app's AppSettingsService default, so a fresh install
# shows a meaningful calendar on both platforms with no setup ritual.
_DEFAULT_BUDGET_KCAL = 2200


@dataclass
class CalendarVars:
    """Tk string variables bound to the History tab's live fields."""

    month_label: tk.StringVar
    streaks: tk.StringVar
    ytd: tk.StringVar
    budget_status: tk.StringVar


@dataclass
class CalendarWidgets:
    """Interactive widgets of the History tab."""

    frame: tk.Frame
    day_cells: list[tk.Label]
    budget_entry: tk.Entry
    budget_edit_button: tk.Button
    budget_status_label: tk.Label


@dataclass
class CalendarCallbacks:
    """Construction-time commands the History tab's widgets fire."""

    on_prev_month: Callable[[], None]
    on_next_month: Callable[[], None]
    on_edit_or_save_budget: Callable[[], None]


def make_calendar_vars(root: tk.Misc) -> CalendarVars:
    """Create the History tab's string variables, all mastered to ``root``."""
    return CalendarVars(
        month_label=tk.StringVar(master=root, value=""),
        streaks=tk.StringVar(master=root, value=""),
        ytd=tk.StringVar(master=root, value=""),
        budget_status=tk.StringVar(master=root, value=""),
    )


def _build_budget_row(
    parent: tk.Frame,
    vars_: CalendarVars,
    on_edit_or_save_budget: Callable[[], None],
) -> tuple[tk.Entry, tk.Button, tk.Label]:
    """Build the budget row; return the entry, its edit button, and status label.

    The entry starts read-only (``state="readonly"``): the budget is
    displayed but not directly typeable.  The button on the right starts
    labelled "Edit"; clicking it makes the entry editable and relabels
    itself "Save" -- a second click validates and persists, then reverts
    both back to their read-only defaults.
    """
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(8, 4))
    tk.Label(
        row,
        text="Daily budget (kcal):",
        font=("Arial", 12),
        bg=BG,
        fg=FG,
    ).pack(side="left")
    entry = tk.Entry(
        row,
        font=("Arial", 13),
        width=8,
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
        justify="center",
        state="readonly",
        readonlybackground=_FIELD_BG,
    )
    entry.pack(side="left", padx=(6, 6), ipady=2)
    edit_button = tk.Button(
        row,
        text="Edit",
        font=("Arial", 12, "bold"),
        bg=_ACCENT,
        fg="#003322",
        activebackground="#00cc66",
        cursor="hand2",
        command=on_edit_or_save_budget,
    )
    edit_button.pack(side="left")
    status_label = tk.Label(
        parent,
        textvariable=vars_.budget_status,
        font=("Arial", 11),
        bg=BG,
        fg=FG,
    )
    status_label.pack(pady=(0, 4))
    return entry, edit_button, status_label


def _build_month_nav(
    parent: tk.Frame,
    vars_: CalendarVars,
    callbacks: CalendarCallbacks,
) -> None:
    """Build the prev/month-label/next header row."""
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(4, 2))
    tk.Button(
        row,
        text="◀",
        font=("Arial", 12, "bold"),
        bg=_FIELD_BG,
        fg=FG,
        command=callbacks.on_prev_month,
        cursor="hand2",
    ).pack(side="left", padx=4)
    tk.Label(
        row,
        textvariable=vars_.month_label,
        font=("Arial", 14, "bold"),
        bg=BG,
        fg=FG,
        width=16,
        justify="center",
    ).pack(side="left")
    tk.Button(
        row,
        text="▶",
        font=("Arial", 12, "bold"),
        bg=_FIELD_BG,
        fg=FG,
        command=callbacks.on_next_month,
        cursor="hand2",
    ).pack(side="left", padx=4)


def _build_grid(parent: tk.Frame) -> list[tk.Label]:
    """Build the fixed 6x7 day-cell grid and return the flat cell list."""
    weekday_row = tk.Frame(parent, bg=BG)
    weekday_row.pack()
    for col, label in enumerate(_WEEKDAY_LABELS):
        tk.Label(
            weekday_row,
            text=label,
            font=("Arial", 10, "bold"),
            bg=BG,
            fg=_MUTED,
            width=4,
        ).grid(row=0, column=col, padx=1)

    grid_frame = tk.Frame(parent, bg=BG)
    grid_frame.pack(pady=(2, 4))
    day_cells: list[tk.Label] = []
    for row in range(_MONTH_ROWS):
        for col in range(7):
            cell = tk.Label(
                grid_frame,
                text="",
                font=("Arial", 11),
                width=4,
                height=2,
                bg=BG,
                fg=FG,
                highlightthickness=2,
                highlightbackground=BG,
            )
            cell.grid(row=row, column=col, padx=1, pady=1)
            day_cells.append(cell)
    return day_cells


def build_calendar_frame(
    root: tk.Misc,
    vars_: CalendarVars,
    callbacks: CalendarCallbacks,
) -> CalendarWidgets:
    """Lay out the History tab and return the widgets the controller drives."""
    frame = tk.Frame(root, bg=BG)
    tk.Label(
        frame,
        text="📅  History",
        font=("Arial", 22, "bold"),
        bg=BG,
        fg=_ACCENT,
    ).pack(pady=(10, 0))

    budget_entry, budget_edit_button, budget_status_label = _build_budget_row(
        frame,
        vars_,
        callbacks.on_edit_or_save_budget,
    )
    _build_month_nav(frame, vars_, callbacks)
    day_cells = _build_grid(frame)

    tk.Label(
        frame,
        textvariable=vars_.streaks,
        font=("Arial", 13, "bold"),
        bg=BG,
        fg=FG,
    ).pack(pady=(6, 0))
    tk.Label(
        frame,
        textvariable=vars_.ytd,
        font=("Arial", 12),
        bg=BG,
        fg=_MUTED,
    ).pack(pady=(2, 8))

    return CalendarWidgets(
        frame=frame,
        day_cells=day_cells,
        budget_entry=budget_entry,
        budget_edit_button=budget_edit_button,
        budget_status_label=budget_status_label,
    )


class _GateCalendar(_GateMealFlow):
    """History tab: calendar, streaks, YTD tally, and budget editing."""

    _cal_vars: CalendarVars
    _cal_widgets: CalendarWidgets
    _cal_year: int
    _cal_month: int
    _cal_editing_budget: bool
    _notebook: ttk.Notebook

    def _build_tabs(self, callbacks: GateCallbacks) -> GateWidgets:
        """Build the ttk.Notebook, wire both tabs, and return the meal widgets.

        The controller stores the returned bundle as ``self._widgets`` exactly
        as it did with the bare ``build_layout`` result before this tab
        existed; the calendar's own vars/widgets are stashed on self.
        """
        today = now_local().date()
        self._cal_year = today.year
        self._cal_month = today.month
        self._cal_editing_budget = False
        self._notebook = ttk.Notebook(self.root)
        self._notebook.place(relx=0, rely=0, relwidth=1, relheight=1)

        widgets = build_layout(
            self._notebook, self._vars, callbacks, demo_mode=self.demo_mode
        )
        self._notebook.add(widgets.frame, text="Log Meal")

        self._cal_vars = make_calendar_vars(self.root)
        cal_callbacks = CalendarCallbacks(
            on_prev_month=self._on_prev_month,
            on_next_month=self._on_next_month,
            on_edit_or_save_budget=self._on_edit_or_save_budget,
        )
        self._cal_widgets = build_calendar_frame(
            self._notebook, self._cal_vars, cal_callbacks
        )
        self._notebook.add(self._cal_widgets.frame, text="History")
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
        cells = self._cal_widgets.day_cells
        for index, cell_widget in enumerate(cells):
            row, col = divmod(index, 7)
            spec = weeks[row][col] if row < len(weeks) else CalendarCell(None, None)
            bg, fg, outline = cell_style(spec.status)
            cell_widget.config(
                text=str(spec.day) if spec.day else "",
                bg=bg,
                fg=fg,
                highlightbackground=outline,
            )

    def _refresh_budget_field(self, budget: int | None) -> None:
        """Show ``budget`` in the (read-only) entry, or leave it blank if unset.

        Temporarily switches to the "normal" Tk state to mutate the text --
        a real ``readonly`` Entry rejects ``.insert``/``.delete`` the same
        as direct typing -- then restores read-only.
        """
        entry = self._cal_widgets.budget_entry
        entry.config(state="normal")
        entry.delete(0, tk.END)
        if budget is not None:
            entry.insert(0, str(budget))
        entry.config(state="readonly")

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

    def _set_budget_status(self, text: str, *, error: bool) -> None:
        """Update the budget-edit status line, red for errors."""
        self._cal_vars.budget_status.set(text)
        self._cal_widgets.budget_status_label.config(fg=ERR if error else FG)

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
            self._cal_widgets.budget_entry.config(state="normal")
            self._cal_widgets.budget_edit_button.config(text="Save")
            self._set_budget_status("", error=False)
            return
        if not self._save_budget_entry():
            return
        self._cal_editing_budget = False
        self._cal_widgets.budget_edit_button.config(text="Edit")
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
        raw = self._cal_widgets.budget_entry.get().strip()
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
