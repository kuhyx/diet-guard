"""Pure meal-slot arithmetic for the diet_guard gate.

This module is deliberately I/O-free and clock-free: every function is a total
function of its ``now`` and ``schedule`` arguments, so the fiddly time-of-day
edges (07:59 vs 08:00, the 20:00->22:00 tail, the midnight reset) are
exhaustively unit-testable without mocking the filesystem or the wall clock.
The stateful "which slots have I actually logged?" question lives in
:mod:`diet_guard._state`; the two are composed in :mod:`diet_guard._gate`.

A "slot" is simply the integer hour at which a meal checkpoint opens (08, 12,
16, 20 by default).  A slot is *elapsed* once its hour has arrived and we are
still inside the daily enforcement window; an elapsed slot with no logged meal
is what makes the gate fire.

``schedule`` is a required argument on every function here, deliberately: it
used to be read from module constants, and a default would let a call site that
was missed during a refactor keep deriving the old fixed hours on one device
only.  That is the split brain this design exists to prevent -- a slot one
device offers and the other does not is a checkpoint that can never be
satisfied.  Making it required lets mypy enumerate the call sites instead.
Callers resolve the value at the impure edge, mirroring how
:mod:`diet_guard._daystatus` takes an explicit budget schedule.
"""

from __future__ import annotations

from datetime import date, datetime, time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from diet_guard._meal_schedule import MealSchedule

_HOURS_PER_DAY = 24


def day_slots(schedule: MealSchedule) -> tuple[int, ...]:
    """Return the meal-slot hours for a day, e.g. ``(8, 12, 16, 20)``.

    Args:
        schedule: The eating window and meal count to derive slots from.

    Returns:
        The slot hours in ascending order.
    """
    return schedule.slots()


def within_enforcement_window(now: datetime, schedule: MealSchedule) -> bool:
    """Return True if ``now`` is inside the daily slot-enforcement window.

    Outside ``[first_slot, enforcement_end)`` the gate never fires, so unlogged
    slots lapse overnight instead of trapping you at 03:00.

    Args:
        now: Reference local time.
        schedule: The schedule in force for that day.

    Returns:
        True if slot enforcement is active at ``now``.
    """
    return schedule.slots()[0] <= now.hour < schedule.enforcement_end_hour


def elapsed_slots(now: datetime, schedule: MealSchedule) -> tuple[int, ...]:
    """Return today's slots whose hour has arrived as of ``now``.

    Empty outside the enforcement window (before the first slot, or after the
    overnight cutoff), so the caller never has to special-case the night.

    Args:
        now: Reference local time.
        schedule: The schedule in force for that day.

    Returns:
        The elapsed slot hours, ascending (possibly empty).
    """
    if not within_enforcement_window(now, schedule):
        return ()
    return tuple(slot for slot in day_slots(schedule) if slot <= now.hour)


def missing_slots(
    now: datetime, logged: set[int], schedule: MealSchedule
) -> tuple[int, ...]:
    """Return elapsed slots that have not been satisfied by a logged meal.

    Args:
        now: Reference local time.
        logged: The set of slot hours already covered by today's log.
        schedule: The schedule in force for that day.

    Returns:
        The unsatisfied elapsed slot hours, ascending (empty == nothing due).
    """
    return tuple(slot for slot in elapsed_slots(now, schedule) if slot not in logged)


def current_slot(now: datetime, schedule: MealSchedule) -> int | None:
    """Return the most recent elapsed slot as of ``now``, or None.

    Reports the schedule position only.  Tagging a *log* with a slot goes
    through :func:`slot_for_log`, which additionally clamps off-hours meals
    instead of returning None.

    Args:
        now: Reference local time.
        schedule: The schedule in force for that day.

    Returns:
        The latest elapsed slot hour, or None when none have elapsed yet.
    """
    elapsed = elapsed_slots(now, schedule)
    return elapsed[-1] if elapsed else None


def slot_for_log(now: datetime, schedule: MealSchedule) -> int:
    """Return the slot a meal logged at ``now`` should be attributed to.

    CLAMP RULE (keep byte-identical with ``slot.dart``'s ``slotForLog``): before
    the first slot, clamp to the first slot; after the enforcement window ends,
    clamp to the last slot; behaviour inside a window is unchanged.  Both
    languages must reach each answer by the *same* branch, not merely agree on
    the value -- ``test_slots.py`` sweeps every hour of the day against several
    schedules for exactly that reason.

    Unlike :func:`current_slot` this never returns None, which is the point: an
    off-hours meal used to satisfy no slot at all, so eating at 07:30 or 22:30
    still left the gate firing for that checkpoint.  Attribution is deliberately
    separate from :func:`elapsed_slots`/:func:`missing_slots` -- widening *those*
    would instead make every slot fall due at the end of the day.

    Args:
        now: Reference local time.
        schedule: The schedule in force for that day.

    Returns:
        The slot hour to tag the log with.
    """
    slots = day_slots(schedule)
    if now.hour < slots[0]:
        return slots[0]
    current = current_slot(now, schedule)
    return current if current is not None else slots[-1]


def resolve_future_when(
    date_str: str, hour: int, schedule: MealSchedule, now: datetime
) -> datetime:
    """Build a tz-aware datetime for a meal pre-logged against a future slot.

    Lets a caller (the CLI's ``--date``/``--hour`` flags, or the app's future-
    date picker) turn a user-picked date+hour into the ``when`` that
    :func:`diet_guard._state.log_meal` expects, with the same validation on
    both platforms. Still clock-free per the module's own rule: ``now`` is
    supplied by the caller rather than read here.

    Args:
        date_str: The chosen date as ``YYYY-MM-DD``.
        hour: The chosen slot hour; must be one of ``schedule``'s slot hours.
        schedule: The schedule in force, used to validate ``hour``.
        now: Reference local time, used to reject a non-future date.

    Returns:
        A tz-aware datetime combining ``date_str`` and ``hour``, in ``now``'s
        timezone.

    Raises:
        ValueError: ``date_str`` doesn't parse, ``hour`` isn't a slot hour, or
            the resulting date isn't strictly after ``now``'s date.
    """
    try:
        parsed_date = date.fromisoformat(date_str)
    except ValueError as exc:
        msg = f"invalid date {date_str!r}, expected YYYY-MM-DD"
        raise ValueError(msg) from exc
    slots = day_slots(schedule)
    if hour not in slots:
        msg = f"hour {hour} is not a meal slot; choose one of {slots}"
        raise ValueError(msg)
    if parsed_date <= now.date():
        msg = f"{date_str} is not a future date"
        raise ValueError(msg)
    return datetime.combine(parsed_date, time(hour=hour), tzinfo=now.tzinfo)


def slot_label(slot: int) -> str:
    """Return a human ``HH:00`` label for a slot hour, e.g. ``"08:00"``."""
    return f"{slot % _HOURS_PER_DAY:02d}:00"
