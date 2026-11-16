"""The open gate window pulls peer logs on its own, every ~30 s.

``watch_credit`` (see :mod:`diet_guard._gatelock_credit`) fires on a *local*
write to the food log, and until 2026-11-16 nothing on the PC wrote while the
window was up: a meal logged on the phone waited for the user to press Fetch.
This runs the Fetch button's own narrow pull -- :func:`pull_peer_logs` through
:func:`start_fetch`, no new sync client -- on a timer. When a peer has logged
something the pull writes the local log, and that write trips the watch.

* **Off the Tk thread**, a daemon worker and a Tk-side poll, exactly as the
  button does it.
* **One pull at a time, shared with the button.** Both use the window's
  ``fetch_result`` slot: a tick while the button's fetch runs does nothing, and
  a click while a tick's pull runs is ignored by the button's own guard.
* **Silent and never an unlock.** No status line (it would say "nothing new"
  every 30 s over whatever the user is doing) and no direct close: the watch
  owns that, on the same ``due_slots`` verdict as every other path.
* **Fail closed.** A failed pull is logged and retried at the next interval; the
  window stays up.
"""

from __future__ import annotations

import logging
import queue
from typing import TYPE_CHECKING, Protocol

from diet_guard._gatelock_fetch import FETCH_POLL_MS, start_fetch
from diet_guard._sync_refresh import pull_peer_logs

if TYPE_CHECKING:
    from collections.abc import Callable
    from tkinter import Misc

__all__ = ["PEER_PULL_MS", "arm_peer_pull"]

_logger = logging.getLogger(__name__)

#: Between the end of one pull and the start of the next. A phone-logged meal
#: closes the window within about this long.
PEER_PULL_MS = 30_000


class _PullHost(Protocol):
    """The slice of the gate window the timer needs."""

    root: Misc
    #: The shared in-flight slot; None when no pull is running.
    fetch_result: queue.Queue[str | None] | None


def _poll_closure(host: _PullHost, interval_ms: int) -> Callable[[], None]:
    """Build the Tk-side poll that collects a finished pull."""

    def _poll() -> None:
        result = host.fetch_result
        if result is None:
            return
        try:
            reason = result.get_nowait()
        except queue.Empty:
            host.root.after(FETCH_POLL_MS, _poll)
            return
        host.fetch_result = None
        if reason is not None:
            _logger.warning("Background peer pull failed, retrying: %s", reason)
        host.root.after(interval_ms, _tick_closure(host, interval_ms))

    return _poll


def _tick_closure(host: _PullHost, interval_ms: int) -> Callable[[], None]:
    """Build the timer callback: start a pull unless one is already running."""

    def _tick() -> None:
        if host.fetch_result is not None:
            host.root.after(interval_ms, _tick)
            return
        host.fetch_result = start_fetch(pull_peer_logs)
        host.root.after(FETCH_POLL_MS, _poll_closure(host, interval_ms))

    return _tick


def arm_peer_pull(host: _PullHost, interval_ms: int = PEER_PULL_MS) -> None:
    """Start pulling peer logs in the background while the window is up.

    Args:
        host: The gate window (its Tk root and shared in-flight pull slot).
        interval_ms: Pause between pulls.
    """
    host.root.after(interval_ms, _tick_closure(host, interval_ms))
