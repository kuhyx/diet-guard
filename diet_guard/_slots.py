"""Pure meal-slot arithmetic for the diet_guard gate.

This module is deliberately I/O-free and clock-free: every function is a total
function of its ``now`` and ``schedule`` arguments, so the fiddly time-of-day
edges (07:59 vs 08:00, the 20:00->22:00 tail, the midnight reset) are
exhaustively unit-testable without mocking the filesystem or the wall clock.
The stateful "which slots have I actually logged?" question lives in
:mod:`diet_guard._state`; the two are composed in :mod:`diet_guard._gate`.

A "slot" is the *minute of day* (``0..1439``) at which a meal checkpoint opens
(480, 720, 960, 1200 -- 08:00, 12:00, 16:00, 20:00 -- by default).  A slot is
*elapsed* once its minute has arrived and we are still inside the daily
enforcement window; an elapsed slot with no logged meal is what makes the gate
fire.  How a log entry records its slot on the wire, and how the old
hour-valued ``slot`` field is read back, lives in :mod:`diet_guard._slot_wire`.

A logged meal satisfies the slot *nearest* its recorded slot minute
(:func:`satisfied_slots`), not only an exact match.  That is how a meal logged
under an old schedule (or an old hour-valued entry) still counts after the
schedule moves by a few minutes -- nothing on disk is ever rewritten.

``schedule`` is a required argument on every function here, deliberately: it
used to be read from module constants, and a default would let a call site that
was missed during a refactor keep deriving the old fixed hours on one device
only.  That is the split brain this design exists to prevent -- a slot one
device offers and the other does not is a checkpoint that can never be
satisfied.  Making it required lets mypy enumerate the call sites instead.
Callers resolve the value at the impure edge, mirroring how
:mod:`diet_guard._daystatus` takes an explicit budget schedule.

KEEP IN SYNC WITH ``app/lib/models/slot.dart``; the shared vectors in
``tests/fixtures/meal_schedule_vectors.json`` gate the two.
"""

from __future__ import annotations

from datetime import date, datetime, time
from typing import TYPE_CHECKING

from diet_guard._meal_schedule import MINUTES_PER_DAY

if TYPE_CHECKING:
    from collections.abc import Iterable

    from diet_guard._meal_schedule import MealSchedule


def minute_of_day(now: datetime) -> int:
    """Return ``now``'s minute of day, ``0..1439`` (seconds are ignored)."""
    return now.hour * 60 + now.minute


def day_slots(schedule: MealSchedule) -> tuple[int, ...]:
    """Return the meal-slot minutes for a day, e.g. ``(480, 720, 960, 1200)``.

    Args:
        schedule: The eating window and meal count to derive slots from.

    Returns:
        The slot minutes in ascending order.
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
    minute = minute_of_day(now)
    return schedule.slots()[0] <= minute < schedule.enforcement_end_minute


def elapsed_slots(now: datetime, schedule: MealSchedule) -> tuple[int, ...]:
    """Return today's slots whose minute has arrived as of ``now``.

    Empty outside the enforcement window (before the first slot, or after the
    overnight cutoff), so the caller never has to special-case the night.

    Args:
        now: Reference local time.
        schedule: The schedule in force for that day.

    Returns:
        The elapsed slot minutes, ascending (possibly empty).
    """
    if not within_enforcement_window(now, schedule):
        return ()
    minute = minute_of_day(now)
    return tuple(slot for slot in day_slots(schedule) if slot <= minute)


def missing_slots(
    now: datetime, logged: set[int], schedule: MealSchedule
) -> tuple[int, ...]:
    """Return elapsed slots that have not been satisfied by a logged meal.

    Args:
        now: Reference local time.
        logged: The slot minutes already covered by today's log -- normally
            :func:`satisfied_slots` of the entries' slot minutes.
        schedule: The schedule in force for that day.

    Returns:
        The unsatisfied elapsed slot minutes, ascending (empty == nothing due).
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
        The latest elapsed slot minute, or None when none have elapsed yet.
    """
    elapsed = elapsed_slots(now, schedule)
    return elapsed[-1] if elapsed else None


def slot_for_log(now: datetime, schedule: MealSchedule) -> int:
    """Return the slot a meal logged at ``now`` should be attributed to.

    CLAMP RULE (keep byte-identical with ``slot.dart``'s ``slotForLog``): before
    the first slot, clamp to the first slot; after the enforcement window ends,
    clamp to the last slot; behaviour inside a window is unchanged.  Both
    languages must reach each answer by the *same* branch, not merely agree on
    the value -- the shared fixture pins every minute edge for exactly that
    reason.

    Unlike :func:`current_slot` this never returns None, which is the point: an
    off-hours meal used to satisfy no slot at all, so eating at 07:30 or 22:30
    still left the gate firing for that checkpoint.  Attribution is deliberately
    separate from :func:`elapsed_slots`/:func:`missing_slots` -- widening *those*
    would instead make every slot fall due at the end of the day.

    Args:
        now: Reference local time.
        schedule: The schedule in force for that day.

    Returns:
        The slot minute to tag the log with.
    """
    slots = day_slots(schedule)
    if minute_of_day(now) < slots[0]:
        return slots[0]
    current = current_slot(now, schedule)
    return current if current is not None else slots[-1]


def nearest_slot(minute: int, schedule: MealSchedule) -> int:
    """Return the slot closest to ``minute``; an exact tie goes to the earlier.

    The tie rule is part of the cross-language contract: ``min`` keeps the
    first minimal element of the ascending slots, and the Dart loop replaces
    its best only on a strictly smaller distance.
    """
    return min(day_slots(schedule), key=lambda slot: abs(slot - minute))


def satisfied_slots(entry_minutes: Iterable[int], schedule: MealSchedule) -> set[int]:
    """Return the slots covered by meals recorded at ``entry_minutes``.

    Each recorded slot minute satisfies its :func:`nearest_slot`.  Many-to-one
    is intended: two meals snapping onto one slot satisfy only that slot, so a
    double breakfast does not also clear lunch.  This is what lets an entry
    written under an older schedule count toward today's nearest checkpoint
    without rewriting it on disk.
    """
    return {nearest_slot(minute, schedule) for minute in entry_minutes}


def resolve_future_when(
    date_str: str, slot_minute: int, schedule: MealSchedule, now: datetime
) -> datetime:
    """Build a tz-aware datetime for a meal pre-logged against a future slot.

    Lets a caller (the CLI's ``--date`` flag, or the app's future-date picker)
    turn a user-picked date+slot into the ``when`` that
    :func:`diet_guard._state.log_meal` expects, with the same validation on
    both platforms. Still clock-free per the module's own rule: ``now`` is
    supplied by the caller rather than read here.

    Args:
        date_str: The chosen date as ``YYYY-MM-DD``.
        slot_minute: The chosen slot; must be one of ``schedule``'s slots.
        schedule: The schedule in force, used to validate ``slot_minute``.
        now: Reference local time, used to reject a non-future date.

    Returns:
        A tz-aware datetime combining ``date_str`` and ``slot_minute``, in
        ``now``'s timezone.

    Raises:
        ValueError: ``date_str`` doesn't parse, ``slot_minute`` isn't a slot,
            or the resulting date isn't strictly after ``now``'s date.
    """
    try:
        parsed_date = date.fromisoformat(date_str)
    except ValueError as exc:
        msg = f"invalid date {date_str!r}, expected YYYY-MM-DD"
        raise ValueError(msg) from exc
    slots = day_slots(schedule)
    if slot_minute not in slots:
        labels = ", ".join(slot_label(slot) for slot in slots)
        msg = f"{slot_label(slot_minute)} is not a meal slot; choose one of {labels}"
        raise ValueError(msg)
    if parsed_date <= now.date():
        msg = f"{date_str} is not a future date"
        raise ValueError(msg)
    clock = time(hour=slot_minute // 60, minute=slot_minute % 60)
    return datetime.combine(parsed_date, clock, tzinfo=now.tzinfo)


def slot_label(minute: int) -> str:
    """Return a human ``HH:MM`` label for a slot minute, e.g. ``"07:15"``."""
    wrapped = minute % MINUTES_PER_DAY
    return f"{wrapped // 60:02d}:{wrapped % 60:02d}"
