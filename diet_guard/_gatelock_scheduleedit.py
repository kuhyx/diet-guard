"""Meal-schedule editing on the gate's History tab.

Sibling of :mod:`._gatelock_budgetedit`, with the same edit/save toggle shape:
the row displays the schedule read-only, "Edit" unlocks it, "Save" validates
and persists.  ``_GateScheduleEdit`` sits between
:class:`~diet_guard._gatelock_budgetedit._GateBudgetEdit` and
:class:`~diet_guard._gatelock_calendar._GateCalendar` in the mixin chain.

Editing here changes what the gate itself asks for, so the value is validated
before it is written rather than relying on
:meth:`~diet_guard._meal_schedule.MealSchedule.normalized` to clamp it.  The
clamp is the defence against a peer's corrupt sync data; a typo at the
keyboard should say so instead of silently becoming a different schedule.

The first and last meal are ``HH:MM`` times (any minute, not just the
quarter hours the dropdown offers); the rules mirror ``normalized()`` exactly
so that a schedule accepted here is stored unchanged.
"""

from __future__ import annotations

import abc
import contextlib
import tkinter as tk

from diet_guard._gatelock_budgetedit import _GateBudgetEdit
from diet_guard._gatelock_ui import ERR, FG
from diet_guard._meal_schedule import (
    MAX_MEAL_COUNT,
    MIN_MEAL_COUNT,
    SLOT_GRID_MINUTES,
    MealSchedule,
)
from diet_guard._meal_schedule_store import current_schedule, record_schedule_change
from diet_guard._slot_wire import parse_hhmm
from diet_guard._slots import day_slots, slot_label

__all__ = ["_GateScheduleEdit", "schedule_problem", "schedule_summary"]

# ttk.Combobox and tk.Entry spell "locked" differently: a ``readonly``
# combobox still lets the user pick from its list, so locked is ``disabled``.
_COMBO_STATE = {"normal": "normal", "readonly": "disabled"}


def schedule_summary(schedule: MealSchedule) -> str:
    """Return the derived checkpoint times, e.g. ``"08:00  11:00  ..."``."""
    return "  ".join(slot_label(slot) for slot in day_slots(schedule))


def schedule_problem(schedule: MealSchedule) -> str | None:
    """Return why ``schedule`` cannot be saved as typed, or None if it can.

    Each rule is one ``normalized()`` would otherwise apply silently: the
    15-minute minimum window, the meal-count range, and the capacity of the
    window -- one checkpoint per grid step, because two meals closer than that
    would snap onto the same quarter hour and a duplicate slot silently drops
    a checkpoint.
    """
    first, last = schedule.first_minute, schedule.last_minute
    if last < first + SLOT_GRID_MINUTES:
        return (
            f"The last meal must be at least {SLOT_GRID_MINUTES} min after the first."
        )
    if not MIN_MEAL_COUNT <= schedule.count <= MAX_MEAL_COUNT:
        return f"Meals per day must be {MIN_MEAL_COUNT}-{MAX_MEAL_COUNT}."
    if schedule.count > (last - first) // SLOT_GRID_MINUTES + 1:
        return "Too many meals for that window -- widen it or eat less often."
    return None


class _GateScheduleEdit(_GateBudgetEdit):
    """The History tab's meal-schedule row: display, edit, validate, persist.

    Like :class:`~diet_guard._gatelock_budgetedit._GateBudgetEdit`, this half
    only reads and writes its own row; the tab's construction and refresh are
    owned by :class:`~diet_guard._gatelock_calendar._GateCalendar`, further
    down the mixin chain.
    """

    _cal_editing_schedule: bool

    @abc.abstractmethod
    def _refresh_calendar(self) -> None:
        """Repaint the History tab; implemented by ``_GateCalendar``."""

    def _set_schedule_entry_state(self, state: str) -> None:
        """Lock (``"readonly"``) or unlock (``"normal"``) the row's fields.

        One suppress per widget: a monitor that vanished mid-update must not
        stop the remaining fields from changing state.
        """
        for surface in self._cal_surfaces:
            for combo in (surface.schedule_first_entry, surface.schedule_last_entry):
                with contextlib.suppress(tk.TclError):
                    combo.config(state=_COMBO_STATE[state])
            with contextlib.suppress(tk.TclError):
                surface.schedule_count_entry.config(state=state)

    def _set_schedule_button_text(self, text: str) -> None:
        """Relabel the schedule edit/save button on every monitor."""
        for surface in self._cal_surfaces:
            with contextlib.suppress(tk.TclError):
                surface.schedule_edit_button.config(text=text)

    def _set_schedule_status(self, text: str, *, error: bool) -> None:
        """Update the schedule-edit status line, red for errors."""
        self._cal_vars.schedule.status.set(text)
        colour = ERR if error else FG
        for surface in self._cal_surfaces:
            with contextlib.suppress(tk.TclError):
                surface.schedule_status_label.config(fg=colour)

    def _show_schedule(self, schedule: MealSchedule) -> None:
        """Populate the row's fields and derived-times label."""
        self._cal_vars.schedule.first.set(slot_label(schedule.first_minute))
        self._cal_vars.schedule.last.set(slot_label(schedule.last_minute))
        self._cal_vars.schedule.count.set(str(schedule.count))
        self._cal_vars.schedule.times.set(schedule_summary(schedule))

    def _on_edit_or_save_schedule(self) -> None:
        """Toggle the schedule row between read-only display and editing.

        Mirrors :meth:`_GateBudgetEdit._on_edit_or_save_budget`: a failed
        validation leaves editing open so the value can be corrected rather
        than silently discarded.
        """
        if not self._cal_editing_schedule:
            self._cal_editing_schedule = True
            self._set_schedule_entry_state("normal")
            self._set_schedule_button_text("Save")
            self._set_schedule_status("", error=False)
            return
        if not self._save_schedule_entry():
            return
        self._cal_editing_schedule = False
        self._set_schedule_entry_state("readonly")
        self._set_schedule_button_text("Edit")
        self._refresh_calendar()

    def _read_schedule_fields(self) -> MealSchedule | None:
        """Parse the three fields, or None (with a status set) if unusable."""
        try:
            first = parse_hhmm(self._cal_vars.schedule.first.get())
            last = parse_hhmm(self._cal_vars.schedule.last.get())
        except ValueError:
            self._set_schedule_status(
                "Enter meal times as HH:MM, e.g. 07:15.", error=True
            )
            return None
        try:
            count = int(self._cal_vars.schedule.count.get().strip())
        except ValueError:
            self._set_schedule_status("Enter meals per day as a number.", error=True)
            return None
        return MealSchedule(first, last, count)

    def _save_schedule_entry(self) -> bool:
        """Validate and persist the row's current values.

        Returns:
            Whether the schedule was valid and persisted.
        """
        schedule = self._read_schedule_fields()
        if schedule is None:
            return False
        problem = schedule_problem(schedule)
        if problem is not None:
            self._set_schedule_status(problem, error=True)
            return False
        record_schedule_change(schedule)
        self._show_schedule(current_schedule())
        self._set_schedule_status("Saved.", error=False)
        return True
