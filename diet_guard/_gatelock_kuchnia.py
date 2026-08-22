"""Off-thread catering fetch for the lock screen's "Load delivery" button.

Its own module because :mod:`diet_guard._gatelock_mealflow` is already at the
repo's 250-line cap, and because the worker contract here is worth stating
once, plainly.

Modelled on :mod:`diet_guard._gatelock_fetch`, but it cannot reuse
:func:`~diet_guard._gatelock_fetch.start_fetch`: that is typed
``Callable[[], str | None] -> Queue[str | None]`` and this fetch returns
*dishes*.  Squeezing them through by stashing results on the instance from the
worker would reintroduce exactly the cross-thread state that module's docstring
exists to forbid, so the pattern is copied rather than bent:

* **The worker touches no widget.**  Tcl is not thread-safe, and that includes
  ``after`` -- the worker only ``put``s on a queue, and a poll scheduled on the
  Tk thread picks it up.  That also makes the completion path testable with no
  thread at all: put a result, call the poll, assert.
* **The worker always feeds the queue**, even if the call raises.  It has
  nowhere to propagate to, so an escaping exception would leave the poll
  waiting forever with the button disabled and the user stuck behind the lock.
* **Daemon thread**, so a hung request can never keep the process alive after
  the window is gone -- the gate is a ``Type=oneshot`` unit and must exit.

Nothing here logs anything.  The fetch only *offers* dishes; writing entries is
a separate, explicitly confirmed step (:mod:`diet_guard._kuchnia_log`).
"""

from __future__ import annotations

from collections.abc import Callable
from contextlib import suppress
import queue
import threading
from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Sequence
    from datetime import date

    from diet_guard._kuchnia_parse import Dish

#: What ``_kuchnia_import.refresh_delivery`` looks like to this module.
RefreshFn = Callable[["date"], tuple["Sequence[Dish]", "str | None"]]


class DeliveryResult(NamedTuple):
    """What the worker hands back: the dishes, or why there are none."""

    dishes: tuple[Dish, ...]
    reason: str | None


#: Reported when the worker itself fails unexpectedly. ``refresh_delivery`` is
#: already fail-closed, so reaching this means a bug rather than an outage.
UNEXPECTED = "catering fetch failed (unexpected error)"


def start_delivery_fetch(
    refresh: RefreshFn,
    day: date,
) -> queue.Queue[DeliveryResult]:
    """Run ``refresh(day)`` on a daemon thread; return its result queue.

    Args:
        refresh: A ``refresh_delivery``-shaped callable returning
            ``(dishes, reason)``. Passed in rather than imported so the gate
            can be tested without an HTTP stack.
        day: The delivery date to fetch.

    Returns:
        A queue that will receive exactly one :class:`DeliveryResult`.
    """
    result: queue.Queue[DeliveryResult] = queue.Queue(maxsize=1)

    def _worker() -> None:
        """Runs OFF the Tk thread. Touches no widget, by construction."""
        outcome = DeliveryResult(dishes=(), reason=UNEXPECTED)
        # ``refresh`` is already fail-closed, so an exception here is a bug --
        # but it must not escape this thread. There is nowhere to propagate to,
        # so it would surface only as an unraisable-thread warning while the
        # poll waits forever and the user stays stuck behind the lock.
        # ``suppress`` rather than a broad ``except``; the pre-seeded UNEXPECTED
        # outcome is what reaches the window.
        with suppress(Exception):
            dishes, reason = refresh(day)
            outcome = DeliveryResult(dishes=tuple(dishes), reason=reason)
        result.put(outcome)

    threading.Thread(target=_worker, daemon=True).start()
    return result
