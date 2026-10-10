"""The History tab's meal-schedule row widgets.

Split out of :mod:`._gatelock_calendar_widgets` (216 lines against the repo's
250-line cap) rather than added to it.  The behaviour behind these widgets
lives in :mod:`._gatelock_scheduleedit`, mirroring how the budget row's
widgets and its edit/save logic are split.

The first and last meal are editable ``ttk.Spinbox`` fields: the user may type
any ``HH:MM``, and the arrow buttons, Up/Down and the mouse wheel step to the
neighbouring quarter hour (:func:`step_time`).  The ``ttk`` import is
load-bearing for the tests, which patch this module's ``ttk`` with a fake --
keep binding it at module level.

**No popup of any kind.**  These used to be ``ttk.Combobox`` fields, and on
Xvfb (2026-10-10, demo gate) a posted ``ComboboxPopdown`` mapped *beneath*
the lock surface, which gatelock keeps raised, while still holding ttk's grab:
invisible, it swallowed the next click and stole keystrokes.  A spinbox posts
nothing.  Every way ttk spins one -- arrow press, Up/Down, the wheel --
generates ``<<Increment>>``/``<<Decrement>>`` (``ttk/spinbox.tcl``), and those
are bound here and answered with ``"break"``, so ttk's own ``values``/``wrap``
logic never runs: stepping is always :func:`step_time` from the typed value.
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

__all__ = ["FIRST_RANGE", "LAST_RANGE", "build_schedule_row", "step_time"]

_ENTRY_WIDTH = 4
# "HH:MM" plus room for the caret, so a typed time is never clipped.
_TIME_WIDTH = 6

_LAST_MARK = MINUTES_PER_DAY - SLOT_GRID_MINUTES  # 23:45, the day's last grid mark

#: Where stepping clamps each field, as ``(low, high)`` minutes.  The last meal
#: must sit at least one grid step after the first, so it can never be 00:00.
FIRST_RANGE = (0, _LAST_MARK)
LAST_RANGE = (SLOT_GRID_MINUTES, _LAST_MARK)


def step_time(text: str, direction: int, bounds: tuple[int, int] = FIRST_RANGE) -> str:
    """Return ``text`` moved to the next quarter hour in ``direction``.

    An off-grid time (07:23) steps to the neighbouring grid mark (07:30 up,
    07:15 down) rather than by a flat 15, so stepping always lands on the
    grid.  Clamped to ``bounds``; unparsable text is returned unchanged so a
    half-typed value is not clobbered.

    Args:
        text: The field's current value.
        direction: ``+1`` for later, ``-1`` for earlier.
        bounds: The ``(low, high)`` minutes the result is clamped to.

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
    low, high = bounds
    return slot_label(max(low, min(high, stepped)))


def _bind_steps(
    spin: ttk.Spinbox, variable: tk.StringVar, bounds: tuple[int, int]
) -> None:
    """Answer the spinbox's step events with :func:`step_time`."""

    def _step(direction: int) -> str:
        if str(spin.cget("state")) == "normal":
            variable.set(step_time(variable.get(), direction, bounds))
        # "break" keeps ttk's own Spin (values/from/to/wrap) from running.
        return "break"

    spin.bind("<<Increment>>", lambda _event: _step(1))
    spin.bind("<<Decrement>>", lambda _event: _step(-1))


def _time_spin(
    row: tk.Frame, variable: tk.StringVar, bounds: tuple[int, int]
) -> ttk.Spinbox:
    """Return one locked-by-default ``HH:MM`` spinbox in the schedule row.

    Locked means ``disabled``, not ``readonly``: a read-only ttk spinbox still
    spins, which would edit a "locked" row.  Its colours come from the
    ``TSpinbox`` style (see
    :func:`diet_guard._gatelock_calendar_ui._style_notebook`) -- ttk widgets
    reject ``bg``/``fg``.
    """
    spin = ttk.Spinbox(
        row,
        textvariable=variable,
        font=(_COLORS.typography.font_family, BODY),
        width=_TIME_WIDTH,
        justify="center",
        state="disabled",
    )
    _bind_steps(spin, variable, bounds)
    spin.pack(side="left", padx=(XS, SM), ipady=XS)
    return spin


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
) -> tuple[ttk.Spinbox, ttk.Spinbox, tk.Entry, tk.Button, tk.Label]:
    """Build the meal-schedule row.

    Returns the two time spinboxes, the count entry, the edit button, and the
    status label, in that order.  Like the budget row the fields start locked:
    the schedule is displayed but not directly editable until "Edit".

    Returns:
        ``(first_spin, last_spin, count_entry, edit_button, status_label)``.
    """
    row = tk.Frame(parent, bg=BG)
    row.pack(pady=(SM, XS))
    _caption(row, "Meals:")
    first_spin = _time_spin(row, vars_.schedule.first, FIRST_RANGE)
    _caption(row, "to")
    last_spin = _time_spin(row, vars_.schedule.last, LAST_RANGE)
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
    return first_spin, last_spin, count_entry, edit_button, status_label
