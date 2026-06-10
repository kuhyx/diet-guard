"""Decision logic for the diet_guard slot-based log-to-unlock gate.

This module is GUI-free and side-effect-free so the lock/no-lock decision can
be verified headlessly: the fullscreen window in ``_gatelock.py`` is only a
thin shell around :func:`gate_is_due` and :func:`due_slots`.  It composes the
pure slot arithmetic in :mod:`python_pkg.diet_guard._slots` with the logged-slot
state in :mod:`python_pkg.diet_guard._state`; ``now`` is injectable so the
time-of-day rules stay deterministically testable.

The gate fires when any *elapsed* meal slot for today carries no logged meal.
Coming home late therefore surfaces several unlogged slots at once -- a single
lock that backfills the whole day before the PC is usable -- while a normal day
prompts one slot at a time, with no separate weekday code path.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from python_pkg.diet_guard._slots import missing_slots, slot_label
from python_pkg.diet_guard._state import logged_slots_today, now_local

if TYPE_CHECKING:
    from datetime import datetime


def due_slots(now: datetime | None = None) -> tuple[int, ...]:
    """Return today's elapsed-but-unlogged meal slots, ascending.

    Args:
        now: Reference time (defaults to the current local time); injectable.

    Returns:
        The slot hours that still need a meal logged (empty == nothing due).
    """
    reference = now if now is not None else now_local()
    return missing_slots(reference, logged_slots_today())


def gate_is_due(now: datetime | None = None) -> bool:
    """Return True if the screen should lock until the missing slots are filled.

    Args:
        now: Reference time (defaults to the current local time); injectable.

    Returns:
        True if at least one elapsed slot today is unlogged, else False.
    """
    return bool(due_slots(now))


def gate_message(now: datetime | None = None) -> str:
    """Return the lock-screen reason line listing the slots to backfill.

    Args:
        now: Reference time (defaults to the current local time); injectable.

    Returns:
        A short human-readable explanation of which meals are missing.
    """
    missing = due_slots(now)
    if not missing:
        return "All meals are logged. You're up to date."
    labels = ", ".join(slot_label(slot) for slot in missing)
    if len(missing) == 1:
        return f"Log your {labels} meal to unlock."
    return f"Log your meals for {labels} to unlock."
