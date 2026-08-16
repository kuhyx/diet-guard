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
"""

from __future__ import annotations

import abc
import contextlib
import tkinter as tk

from diet_guard._gatelock_budgetedit import _GateBudgetEdit
from diet_guard._gatelock_ui import ERR, FG
from diet_guard._meal_schedule import (
    FIRST_HOUR,
    LAST_HOUR,
    MAX_MEAL_COUNT,
    MIN_MEAL_COUNT,
    MealSchedule,
)
from diet_guard._meal_schedule_store import current_schedule, record_schedule_change
from diet_guard._slots import day_slots, slot_label

__all__ = ["_GateScheduleEdit", "schedule_summary"]


def schedule_summary(schedule: MealSchedule) -> str:
    """Return the derived checkpoint times, e.g. ``"08:00  11:00  ..."``."""
    return "  ".join(slot_label(slot) for slot in day_slots(schedule))


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
        """Lock or unlock the three schedule entries on every monitor."""
        for surface in self._cal_surfaces:
            with contextlib.suppress(tk.TclError):
                surface.schedule_first_entry.config(state=state)
                surface.schedule_last_entry.config(state=state)
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
        self._cal_vars.schedule.first.set(str(schedule.first))
        self._cal_vars.schedule.last.set(str(schedule.last))
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
        """Parse the three entries, or None (with a status set) if unusable."""
        raw = (
            self._cal_vars.schedule.first.get().strip(),
            self._cal_vars.schedule.last.get().strip(),
            self._cal_vars.schedule.count.get().strip(),
        )
        try:
            first, last, count = (int(value) for value in raw)
        except ValueError:
            self._set_schedule_status("Enter whole hours, e.g. 8 20 5.", error=True)
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
        if not FIRST_HOUR <= schedule.first < schedule.last <= LAST_HOUR:
            self._set_schedule_status(
                f"First meal must be before the last, both {FIRST_HOUR}-{LAST_HOUR}.",
                error=True,
            )
            return False
        if not MIN_MEAL_COUNT <= schedule.count <= MAX_MEAL_COUNT:
            self._set_schedule_status(
                f"Meals per day must be {MIN_MEAL_COUNT}-{MAX_MEAL_COUNT}.",
                error=True,
            )
            return False
        # A window of N hours holds at most N+1 whole-hour checkpoints; asking
        # for more would round two meals onto the same hour.
        if schedule.count > schedule.last - schedule.first + 1:
            self._set_schedule_status(
                "Too many meals for that window -- widen it or eat less often.",
                error=True,
            )
            return False
        record_schedule_change(schedule)
        self._show_schedule(current_schedule())
        self._set_schedule_status("Saved.", error=False)
        return True
