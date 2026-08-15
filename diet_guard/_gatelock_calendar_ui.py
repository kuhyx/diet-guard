"""Widget construction for the gate's History tab.

Split out of ``_gatelock_calendar`` (and re-exported from it) so neither
module exceeds the repo's 500-line limit. This half builds the tab; the
other half is the controller mixin that drives it, once per live output
since the gatelock v0.2.0 migration.
"""

from __future__ import annotations

from dataclasses import dataclass
import tkinter as tk
from tkinter import ttk
from typing import TYPE_CHECKING

from gatelock import ButtonStyle, LockConfig, make_button

from diet_guard._gatelock_spacing import MD, SM, XS
from diet_guard._gatelock_typography import BODY, CAPTION, LABEL, TITLE
from diet_guard._gatelock_ui import (
    BG,
    FG,
)

if TYPE_CHECKING:
    from collections.abc import Callable

# BG/FG/ERR come from _gatelock_ui's public exports (themselves sourced from
# LockConfig -- see DESIGN_AUDIT_TODO.md). The rest of the calendar's palette
# used to be its own hardcoded copy of _gatelock_ui's private constants; now
# it reads the same shared LockConfig() directly instead.
_COLORS = LockConfig()
_MUTED = _COLORS.muted
_FIELD_BG = _COLORS.field_bg
_ACCENT = _COLORS.accent

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
    averages: tk.StringVar
    budget_status: tk.StringVar
    budget: tk.StringVar
    """Backs the budget entry so its per-monitor copies cannot disagree."""


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
        averages=tk.StringVar(master=root, value=""),
        budget_status=tk.StringVar(master=root, value=""),
        budget=tk.StringVar(master=root, value=""),
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
    )


def _style_notebook(root: tk.Misc) -> None:
    """Theme the ``ttk.Notebook`` tab strip to match the gate's dark palette.

    ``ttk`` widgets ignore plain ``bg=``/``fg=`` -- unlike every other widget
    here, they only take color from a named ``ttk.Style``. Without this the
    tab strip renders in the OS's default (light) ttk theme regardless of how
    dark the rest of the gate is. ``clam`` is used because it is the ttk
    theme that reliably honors ``.configure()`` overrides cross-platform; the
    built-in ``default``/``alt`` themes on some platforms ignore custom tab
    colors.
    """
    style = ttk.Style(root)
    style.theme_use("clam")
    style.configure("TNotebook", background=BG, borderwidth=0)
    style.configure(
        "TNotebook.Tab",
        background=_FIELD_BG,
        foreground=FG,
        padding=(MD, SM),
        borderwidth=0,
    )
    style.map(
        "TNotebook.Tab",
        background=[("selected", _ACCENT)],
        foreground=[("selected", _COLORS.on_fill)],
    )
