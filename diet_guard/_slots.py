"""Pure meal-slot arithmetic for the diet_guard gate.

This module is deliberately I/O-free and clock-free: every function is a total
function of its ``now`` argument and the configured slot constants, so the
fiddly time-of-day edges (07:59 vs 08:00, the 20:00->22:00 tail, the midnight
reset) are exhaustively unit-testable without mocking the filesystem or the
wall clock.  The stateful "which slots have I actually logged?" question lives
in :mod:`python_pkg.diet_guard._state`; the two are composed in
:mod:`python_pkg.diet_guard._gate`.

A "slot" is simply the integer hour at which a meal checkpoint opens (08, 12,
16, 20).  A slot is *elapsed* once its hour has arrived and we are still inside
the daily enforcement window; an elapsed slot with no logged meal is what makes
the gate fire.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from python_pkg.diet_guard._constants import (
    GATE_DAY_START_HOUR,
    GATE_EATING_END_HOUR,
    GATE_SLOT_INTERVAL_HOURS,
)

if TYPE_CHECKING:
    from datetime import datetime

_HOURS_PER_DAY = 24


def day_slots() -> tuple[int, ...]:
    """Return the fixed meal-slot hours for a day, e.g. ``(8, 12, 16, 20)``.

    Slots run from the day-start hour, every interval, up to (but not past) the
    overnight cutoff.  Derived from the constants so changing the cadence in one
    place reshapes the whole schedule.

    Returns:
        The slot hours in ascending order.
    """
    return tuple(
        range(GATE_DAY_START_HOUR, GATE_EATING_END_HOUR, GATE_SLOT_INTERVAL_HOURS)
    )


def within_enforcement_window(now: datetime) -> bool:
    """Return True if ``now`` is inside the daily slot-enforcement window.

    Outside ``[day_start, eating_end)`` the gate never fires, so unlogged slots
    lapse overnight instead of trapping you at 03:00.

    Args:
        now: Reference local time.

    Returns:
        True if slot enforcement is active at ``now``.
    """
    return GATE_DAY_START_HOUR <= now.hour < GATE_EATING_END_HOUR


def elapsed_slots(now: datetime) -> tuple[int, ...]:
    """Return today's slots whose hour has arrived as of ``now``.

    Empty outside the enforcement window (before the first slot, or after the
    overnight cutoff), so the caller never has to special-case the night.

    Args:
        now: Reference local time.

    Returns:
        The elapsed slot hours, ascending (possibly empty).
    """
    if not within_enforcement_window(now):
        return ()
    return tuple(slot for slot in day_slots() if slot <= now.hour)


def missing_slots(now: datetime, logged: set[int]) -> tuple[int, ...]:
    """Return elapsed slots that have not been satisfied by a logged meal.

    Args:
        now: Reference local time.
        logged: The set of slot hours already covered by today's log.

    Returns:
        The unsatisfied elapsed slot hours, ascending (empty == nothing due).
    """
    return tuple(slot for slot in elapsed_slots(now) if slot not in logged)


def current_slot(now: datetime) -> int | None:
    """Return the most recent elapsed slot as of ``now``, or None.

    Used to tag a meal logged through the plain ``ate`` CLI with the slot it
    belongs to, so it counts toward that checkpoint.

    Args:
        now: Reference local time.

    Returns:
        The latest elapsed slot hour, or None when none have elapsed yet.
    """
    elapsed = elapsed_slots(now)
    return elapsed[-1] if elapsed else None


def slot_label(slot: int) -> str:
    """Return a human ``HH:00`` label for a slot hour, e.g. ``"08:00"``."""
    return f"{slot % _HOURS_PER_DAY:02d}:00"
