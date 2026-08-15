"""Data bundles, palette and constants for the gate's History tab.

Split out of :mod:`._gatelock_calendar_ui` to keep every gate module under the
repo's 250-line limit.  This module is the tab's *shared foundation*: the
three dataclasses that cross the module boundary, the calendar constants, and
the palette read from the shared ``LockConfig``.  It is deliberately free of
widget construction, so the builders in
:mod:`._gatelock_calendar_widgets` and the controller in
:mod:`._gatelock_calendar` can both import from it without a cycle.
"""

from __future__ import annotations

from dataclasses import dataclass
import tkinter as tk
from typing import TYPE_CHECKING

from gatelock import LockConfig

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

__all__ = [
    "CalendarCallbacks",
    "CalendarVars",
    "CalendarWidgets",
    "make_calendar_vars",
]


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
