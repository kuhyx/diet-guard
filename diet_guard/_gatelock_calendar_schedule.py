"""The History tab's meal-schedule row widgets.

Split out of :mod:`._gatelock_calendar_widgets` (216 lines against the repo's
250-line cap) rather than added to it.  The behaviour behind these widgets
lives in :mod:`._gatelock_scheduleedit`, mirroring how the budget row's
widgets and its edit/save logic are split.

The first and last meal are editable ``ttk.Combobox`` fields: the dropdown
offers every quarter hour, and the user may also type any ``HH:MM``.  The
``ttk`` import is load-bearing for the tests, which patch this module's
``ttk`` with a fake -- keep binding it at module level.

**The dropdown is a popup over a grabbed lock.**  gatelock's grab watch treats
a ``ttk.Combobox`` popdown as "grab lost" and re-takes the grab within about a
second, which closes the list.  So the list is a convenience, never the only
path: typing works, and Up/Down step the value by 15 minutes *without* posting
the list (:func:`step_time`), which keeps the row fully usable from the
keyboard on the real lock.
"""

from __future__ import annotations

import tkinter as tk
from tkinter import ttk
from typing import TYPE_CHECKING

from gatelock import make_button

from diet_guard._gatelock_calendar_types import _COLORS, _FIELD_BG
from diet_guard._gatelock_spacing import SM, XS
from diet_guard._gatelock_typography import BODY, LABEL
from diet_guard._gatelock_ui import BG, FG
from diet_guard._meal_schedule import MINUTES_PER_DAY, SLOT_GRID_MINUTES
from diet_guard._slot_wire import parse_hhmm
from diet_guard._slots import slot_label

if TYPE_CHECKING:
    from collections.abc import Callable

    from diet_guard._gatelock_calendar_types import CalendarVars

__all__ = ["TIME_CHOICES", "build_schedule_row", "step_time"]

_ENTRY_WIDTH = 4
# "HH:MM" plus room for the caret, so a typed time is never clipped.
_TIME_WIDTH = 6

#: Every quarter hour of the day, the grid interior slots are rounded onto.
TIME_CHOICES = tuple(
    slot_label(minute) for minute in range(0, MINUTES_PER_DAY, SLOT_GRID_MINUTES)
)


def step_time(text: str, direction: int) -> str:
    """Return ``text`` moved to the next quarter hour in ``direction``.

    An off-grid time (07:23) steps to the neighbouring grid mark (07:30 up,
    07:15 down) rather than by a flat 15, so stepping always lands on a value
    the dropdown offers.  Clamped to the day; unparsable text is returned
    unchanged so a half-typed value is not clobbered.

    Args:
        text: The field's current value.
        direction: ``+1`` for later, ``-1`` for earlier.

    Returns:
        The stepped ``HH:MM`` label, or ``text`` if it does not parse.
    """
    try:
        minute = parse_hhmm(text)
    except ValueError:
        return text
    if direction > 0:
        stepped = (minute // SLOT_GRID_MINUTES + 1) * SLOT_GRID_MINUTES
    else:
        stepped = (minute - 1) // SLOT_GRID_MINUTES * SLOT_GRID_MINUTES
    last_mark = MINUTES_PER_DAY - SLOT_GRID_MINUTES
    return slot_label(max(0, min(last_mark, stepped)))


def _bind_steps(combo: ttk.Combobox, variable: tk.StringVar) -> None:
    """Make Up/Down step the time instead of posting the dropdown list."""

    def _step(direction: int) -> str:
        if str(combo.cget("state")) == "normal":
            variable.set(step_time(variable.get(), direction))
        # "break" stops ttk's own binding, which would post the popdown.
        return "break"

    combo.bind("<Up>", lambda _event: _step(1))
    combo.bind("<Down>", lambda _event: _step(-1))


def _time_combo(row: tk.Frame, variable: tk.StringVar) -> ttk.Combobox:
    """Return one locked-by-default ``HH:MM`` combobox in the schedule row.

    Locked means ``disabled``, not ``readonly``: a read-only ttk combobox still
    lets the user pick from the list, which would edit a "locked" row.  Its
    colours come from the ``TCombobox`` style (see
    :func:`diet_guard._gatelock_calendar_ui._style_notebook`) -- ttk widgets
    reject ``bg``/``fg``.
    """
    combo = ttk.Combobox(
        row,
        textvariable=variable,
        values=TIME_CHOICES,
        font=(_COLORS.typography.font_family, BODY),
        width=_TIME_WIDTH,
        justify="center",
        state="disabled",
    )
    _bind_steps(combo, variable)
    combo.pack(side="left", padx=(XS, SM), ipady=XS)
    return combo


def _spin_entry(row: tk.Frame, variable: tk.StringVar) -> tk.Entry:
    """Return the read-only-by-default meal-count entry in the schedule row."""
    entry = tk.Entry(
        row,
        textvariable=variable,
        font=(_COLORS.typography.font_family, BODY),
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


def _caption(row: tk.Frame, text: str) -> None:
    """Pack one static label between the row's fields."""
    tk.Label(
        row,
        text=text,
        font=(_COLORS.typography.font_family, LABEL),
        bg=BG,
        fg=FG,
    ).pack(side="left")


def build_schedule_row(
    parent: tk.Frame,
    vars_: CalendarVars,
    on_edit_or_save_schedule: Callable[[], None],
) -> tuple[ttk.Combobox, ttk.Combobox, tk.Entry, tk.Button, tk.Label]:
    """Build the meal-schedule row.

    Returns the two time comboboxes, the count entry, the edit button, and the
    status label, in that order.  Like the budget row the fields start locked:
    the schedule is displayed but not directly editable until "Edit".

    Returns:
        ``(first_combo, last_combo, count_entry, edit_button, status_label)``.
    """
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(SM, XS))
    _caption(row, "Meals:")
    first_combo = _time_combo(row, vars_.schedule.first)
    _caption(row, "to")
    last_combo = _time_combo(row, vars_.schedule.last)
    _caption(row, "x")
    count_entry = _spin_entry(row, vars_.schedule.count)
    edit_button = make_button(row, _COLORS, "Edit", on_edit_or_save_schedule)
    edit_button.pack(side="left")

    # The derived checkpoint times, so the effect of a change is visible
    # before it is saved rather than only after the next lock.
    tk.Label(
        parent,
        textvariable=vars_.schedule.times,
        font=(_COLORS.typography.font_family, LABEL),
        bg=BG,
        fg=FG,
    ).pack(pady=(0, XS))
    status_label = tk.Label(
        parent,
        textvariable=vars_.schedule.status,
        font=(_COLORS.typography.font_family, LABEL),
        bg=BG,
        fg=FG,
    )
    status_label.pack(pady=(0, XS))
    return first_combo, last_combo, count_entry, edit_button, status_label
