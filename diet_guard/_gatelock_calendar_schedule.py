"""The History tab's meal-schedule row widgets.

Split out of :mod:`._gatelock_calendar_widgets` (216 lines against the repo's
250-line cap) rather than added to it.  The behaviour behind these widgets
lives in :mod:`._gatelock_scheduleedit`, mirroring how the budget row's
widgets and its edit/save logic are split.
"""

from __future__ import annotations

import tkinter as tk
from typing import TYPE_CHECKING

from gatelock import make_button

from diet_guard._gatelock_calendar_types import _COLORS, _FIELD_BG
from diet_guard._gatelock_spacing import SM, XS
from diet_guard._gatelock_typography import BODY, LABEL
from diet_guard._gatelock_ui import BG, FG

if TYPE_CHECKING:
    from collections.abc import Callable

    from diet_guard._gatelock_calendar_types import CalendarVars

__all__ = ["build_schedule_row"]

_ENTRY_WIDTH = 4


def _spin_entry(row: tk.Frame, variable: tk.StringVar) -> tk.Entry:
    """Return one read-only-by-default numeric entry in the schedule row."""
    entry = tk.Entry(
        row,
        textvariable=variable,
        font=(_COLORS.font_family, BODY),
        width=_ENTRY_WIDTH,
        bg=_FIELD_BG,
        fg=FG,
        insertbackground=FG,
        justify="center",
        state="readonly",
        readonlybackground=_FIELD_BG,
    )
    entry.pack(side="left", padx=(XS, SM), ipady=XS)
    return entry


def build_schedule_row(
    parent: tk.Frame,
    vars_: CalendarVars,
    on_edit_or_save_schedule: Callable[[], None],
) -> tuple[tk.Entry, tk.Entry, tk.Entry, tk.Button, tk.Label]:
    """Build the meal-schedule row.

    Returns the three hour/count entries, the edit button, and the status
    label, in that order.  Like the budget row the entries start read-only:
    the schedule is displayed but not directly typeable until "Edit".

    Returns:
        ``(first_entry, last_entry, count_entry, edit_button, status_label)``.
    """
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(SM, XS))
    tk.Label(
        row,
        text="Meals:",
        font=(_COLORS.font_family, LABEL),
        bg=BG,
        fg=FG,
    ).pack(side="left")
    first_entry = _spin_entry(row, vars_.schedule.first)
    tk.Label(
        row,
        text="to",
        font=(_COLORS.font_family, LABEL),
        bg=BG,
        fg=FG,
    ).pack(side="left")
    last_entry = _spin_entry(row, vars_.schedule.last)
    tk.Label(
        row,
        text="x",
        font=(_COLORS.font_family, LABEL),
        bg=BG,
        fg=FG,
    ).pack(side="left")
    count_entry = _spin_entry(row, vars_.schedule.count)
    edit_button = make_button(row, _COLORS, "Edit", on_edit_or_save_schedule)
    edit_button.pack(side="left")

    # The derived checkpoint times, so the effect of a change is visible
    # before it is saved rather than only after the next lock.
    tk.Label(
        parent,
        textvariable=vars_.schedule.times,
        font=(_COLORS.font_family, LABEL),
        bg=BG,
        fg=FG,
    ).pack(pady=(0, XS))
    status_label = tk.Label(
        parent,
        textvariable=vars_.schedule.status,
        font=(_COLORS.font_family, LABEL),
        bg=BG,
        fg=FG,
    )
    status_label.pack(pady=(0, XS))
    return first_entry, last_entry, count_entry, edit_button, status_label
