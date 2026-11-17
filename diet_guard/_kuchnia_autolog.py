"""Log the due slots' catering dishes on the PC before a lock window opens.

kuhy's decision of 2026-11-17 ("LOG EVEN WITHOUT TAP") overrides the old rule
that a delivered meal is not an eaten meal: when the gate is due, today's
delivery is fetched and the dishes that :mod:`diet_guard._kuchnia_spread`
assigns to the *due* slots are logged by themselves. If that satisfies every
due slot, no window opens. Later slots are left alone -- they are logged when
they come due, so a tick at 09:00 never pre-logs the evening.

Each entry's id is :func:`diet_guard._kuchnia_ids.autolog_id`, the same on the
phone, so a repeat run, a second tick and the phone's own copy all collapse to
one entry. A tombstoned (undone) entry still counts as logged.

Every failure is **fail-closed**: nothing is written and the lock opens as it
always did. The fetch sits in front of a fullscreen lock, so it is capped at
:data:`FETCH_TIMEOUT_S` seconds (``docs/DOCS-sync-latency.md``); the worker is a
daemon thread, so an abandoned request cannot keep the oneshot unit alive.

``requests`` is reached lazily (PEP 562 hook below): the gate's common not-due
tick must not pay ~78ms for an HTTP stack it never uses, and ``patch.object``
keeps working on the name.
"""

from __future__ import annotations

from importlib import import_module
import logging
import queue
import sys
from typing import TYPE_CHECKING

from diet_guard._gate import due_slots
from diet_guard._gatelock_kuchnia import start_delivery_fetch
from diet_guard._kuchnia_ids import autolog_id, dish_key
from diet_guard._kuchnia_log import dish_nutrition
from diet_guard._kuchnia_spread import assign_slots
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._slots import day_slots
from diet_guard._state import now_local
from diet_guard._state_sync import find_entry, log_meal_as

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Callable, Sequence
    from datetime import date

    from diet_guard._gatelock_kuchnia import RefreshFn
    from diet_guard._kuchnia_parse import Dish

_logger = logging.getLogger(__name__)

#: Upper bound on the whole catering walk (login + three requests), in seconds.
FETCH_TIMEOUT_S = 5.0


def __getattr__(name: str) -> object:
    """Resolve the deferred catering import on first attribute access."""
    if name != "refresh_delivery":
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    return import_module("diet_guard._kuchnia_import").refresh_delivery


def current_slots() -> tuple[int, ...]:
    """The configured slot minutes of the day."""
    return day_slots(current_schedule())


def fetch_bounded(
    day: date,
    *,
    refresh: RefreshFn | None = None,
    timeout: float = FETCH_TIMEOUT_S,
) -> tuple[list[Dish], str | None]:
    """Fetch ``day``'s dishes, giving up after ``timeout`` seconds.

    Returns:
        ``(dishes, None)``, or ``([], reason)`` on a failed or too-slow fetch.
    """
    fetch = refresh or sys.modules[__name__].refresh_delivery
    result = start_delivery_fetch(fetch, day)
    try:
        outcome = result.get(timeout=timeout)
    except queue.Empty:
        return [], f"catering fetch timed out after {timeout:g}s"
    return list(outcome.dishes), outcome.reason


def log_due_dishes(
    dishes: Sequence[Dish],
    due: Sequence[int],
    day: date,
    slots: Sequence[int],
) -> list[str]:
    """Log the dishes assigned to a due slot; skip ones already logged.

    Returns:
        The descriptions written, in the provider's meal order.
    """
    written: list[str] = []
    for item in assign_slots(dishes, slots):
        if item.slot not in due:
            continue
        key = item.dish.dish_key or dish_key(None, item.dish.name)
        entry_id = autolog_id(day, key)
        if find_entry(entry_id) is not None:
            continue
        log_meal_as(entry_id, item.dish.name, dish_nutrition(item.dish), item.slot)
        written.append(item.dish.name)
    return written


def autolog_due_delivery(emit: Callable[[str], None]) -> int:
    """Auto-log today's catering for the due slots; never raises.

    Returns:
        How many entries were written (0 on any failure: the lock proceeds).
    """
    due = due_slots()
    if not due:
        return 0
    day = now_local().date()
    dishes, reason = fetch_bounded(day)
    if reason is not None:
        # First line only: a missing-credentials reason carries setup steps.
        short = reason.splitlines()[0] if reason else "unknown"
        _logger.warning("catering auto-log skipped: %s", short)
        emit(f"catering auto-log skipped: {short}")
        return 0
    try:
        written = log_due_dishes(dishes, due, day, current_slots())
    except OSError, ValueError:
        _logger.exception("catering auto-log failed while writing")
        emit("catering auto-log skipped: could not write the log (disk error)")
        return 0
    if written:
        emit(f"catering auto-logged: {', '.join(written)}")
    return len(written)
