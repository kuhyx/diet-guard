"""Widget builders for the gate's History tab.

Split out of :mod:`._gatelock_calendar_ui` to keep every gate module under the
repo's 250-line limit.  That module keeps the tab's data bundles, its string
variables, and the ``ttk`` theming; this one builds the actual widgets --
the budget row, the month navigation header, the day grid, and the frame that
holds them.

.. note::
   This module imports ``tkinter`` and builds widgets, so it **must** appear in
   ``diet_guard.tests._gate_fixtures._GATE_TK_MODULES``.  A module left out of
   that set builds real Tk widgets under pytest against fake parents.
   ``test_gate_tk_modules_complete`` enforces this.
"""

from __future__ import annotations

import tkinter as tk
from typing import TYPE_CHECKING

from gatelock import ButtonStyle, make_button

from diet_guard._gatelock_calendar_schedule import build_schedule_row
from diet_guard._gatelock_calendar_types import (
    _ACCENT,
    _COLORS,
    _FIELD_BG,
    _MONTH_ROWS,
    _MUTED,
    _WEEKDAY_LABELS,
    CalendarCallbacks,
    CalendarVars,
    CalendarWidgets,
)
from diet_guard._gatelock_spacing import SM, XS
from diet_guard._gatelock_typography import BODY, CAPTION, LABEL, TITLE
from diet_guard._gatelock_ui import BG, FG

if TYPE_CHECKING:
    from collections.abc import Callable

__all__ = ["build_calendar_frame"]


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
    row.pack(pady=(SM, XS))
    tk.Label(
        row,
        text="Daily budget (kcal):",
        font=(_COLORS.font_family, LABEL),
        bg=BG,
        fg=FG,
    ).pack(side="left")
    entry = tk.Entry(
        row,
        textvariable=vars_.budget,
        font=(_COLORS.font_family, BODY),
        width=8,
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
        justify="center",
        state="readonly",
        readonlybackground=_FIELD_BG,
    )
    entry.pack(side="left", padx=(SM, SM), ipady=XS)
    edit_button = make_button(
        row,
        _COLORS,
        "Edit",
        on_edit_or_save_budget,
    )
    edit_button.pack(side="left")
    status_label = tk.Label(
        parent,
        textvariable=vars_.budget_status,
        font=(_COLORS.font_family, LABEL),
        bg=BG,
        fg=FG,
    )
    status_label.pack(pady=(0, XS))
    return entry, edit_button, status_label


def _build_month_nav(
    parent: tk.Frame,
    vars_: CalendarVars,
    callbacks: CalendarCallbacks,
) -> None:
    """Build the prev/month-label/next header row."""
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(XS, XS))
    make_button(
        row,
        _COLORS,
        "◀",
        callbacks.on_prev_month,
        ButtonStyle(variant="secondary"),
    ).pack(side="left", padx=XS)
    tk.Label(
        row,
        textvariable=vars_.month_label,
        font=(_COLORS.font_family, LABEL, "bold"),
        bg=BG,
        fg=FG,
        width=16,
        justify="center",
    ).pack(side="left")
    make_button(
        row,
        _COLORS,
        "▶",
        callbacks.on_next_month,
        ButtonStyle(variant="secondary"),
    ).pack(side="left", padx=XS)


def _build_grid(parent: tk.Frame) -> list[tk.Label]:
    """Build the fixed 6x7 day-cell grid and return the flat cell list."""
    weekday_row = tk.Frame(parent, bg=BG)
    weekday_row.pack()
    for col, label in enumerate(_WEEKDAY_LABELS):
        tk.Label(
            weekday_row,
            text=label,
            font=(_COLORS.font_family, CAPTION, "bold"),
            bg=BG,
            fg=_MUTED,
            width=4,
        ).grid(row=0, column=col, padx=XS)

    grid_frame = tk.Frame(parent, bg=BG)
    grid_frame.pack(pady=(XS, XS))
    day_cells: list[tk.Label] = []
    for row in range(_MONTH_ROWS):
        for col in range(7):
            cell = tk.Label(
                grid_frame,
                text="",
                font=(_COLORS.font_family, CAPTION),
                width=4,
                height=2,
                bg=BG,
                fg=FG,
                highlightthickness=2,
                highlightbackground=BG,
            )
            cell.grid(row=row, column=col, padx=XS, pady=XS)
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
        font=(_COLORS.font_family, TITLE, "bold"),
        bg=BG,
        fg=_ACCENT,
    ).pack(pady=(SM, 0))

    budget_entry, budget_edit_button, budget_status_label = _build_budget_row(
        frame,
        vars_,
        callbacks.on_edit_or_save_budget,
    )
    (
        schedule_first_entry,
        schedule_last_entry,
        schedule_count_entry,
        schedule_edit_button,
        schedule_status_label,
    ) = build_schedule_row(
        frame,
        vars_,
        callbacks.on_edit_or_save_schedule,
    )
    _build_month_nav(frame, vars_, callbacks)
    day_cells = _build_grid(frame)

    tk.Label(
        frame,
        textvariable=vars_.streaks,
        font=(_COLORS.font_family, LABEL, "bold"),
        bg=BG,
        fg=FG,
    ).pack(pady=(SM, 0))
    tk.Label(
        frame,
        textvariable=vars_.ytd,
        font=(_COLORS.font_family, CAPTION),
        bg=BG,
        fg=_MUTED,
    ).pack(pady=(XS, 0))
    tk.Label(
        frame,
        textvariable=vars_.averages,
        font=(_COLORS.font_family, CAPTION),
        bg=BG,
        fg=_MUTED,
    ).pack(pady=(XS, SM))

    return CalendarWidgets(
        frame=frame,
        day_cells=day_cells,
        budget_entry=budget_entry,
        budget_edit_button=budget_edit_button,
        budget_status_label=budget_status_label,
        schedule_first_entry=schedule_first_entry,
        schedule_last_entry=schedule_last_entry,
        schedule_count_entry=schedule_count_entry,
        schedule_edit_button=schedule_edit_button,
        schedule_status_label=schedule_status_label,
    )
