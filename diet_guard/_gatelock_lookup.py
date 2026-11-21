"""Off-thread plumbing for the lock screen's food lookup.

The lookup used to run on the Tk thread. A food missing from the bank falls
through to an Open Food Facts request (8 s timeout), so the fullscreen lock
froze while it ran: a 1.5 s ``tk.mainloop`` stall was reported (c890f31a).

Same rules as :mod:`._gatelock_fetch`: the worker touches no widget and never
calls ``after`` (Tcl is not thread-safe); it only ``put``s its result on a
queue, and a poll scheduled on the Tk thread picks it up.
"""

from __future__ import annotations

import logging
import queue
import threading
from typing import TYPE_CHECKING

from diet_guard._gatelock_fetch import FETCH_POLL_MS
from diet_guard._resolve import lookup_candidates

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Callable
    from tkinter import Misc

    from diet_guard._estimator import Nutrition

    Candidates = list[tuple[str, Nutrition]]

__all__ = ["LookupRunner", "start_lookup"]

_logger = logging.getLogger(__name__)


def start_lookup(
    lookup: Callable[[str], Candidates],
    description: str,
) -> queue.Queue[Candidates]:
    """Run ``lookup(description)`` on a daemon thread; return the result queue.

    Daemon so a hung request can never keep the process alive after the window
    is gone -- the gate is a ``Type=oneshot`` unit and must exit.
    """
    result: queue.Queue[Candidates] = queue.Queue(maxsize=1)

    def _worker() -> None:
        """Runs OFF the Tk thread. Touches no widget, by construction."""
        candidates: Candidates = []
        try:
            candidates = lookup(description)
        # An unreadable bank or a malformed OFF payload; network errors are
        # already caught inside ``off_candidates``.
        except OSError, ValueError, KeyError, TypeError:
            _logger.exception("food lookup failed")
        finally:
            # Always feed the queue, so the poll never waits forever and the
            # form never stays busy. An empty result asks for a manual kcal.
            result.put(candidates)

    threading.Thread(target=_worker, daemon=True).start()
    return result


class LookupRunner:
    """One food lookup at a time, collected on the Tk thread.

    The window stays live while a lookup runs, so the user can log the meal by
    hand and move on. A result for a food no longer in the description box is
    dropped: applied late, it would fill the next slot with the wrong macros.
    """

    def __init__(
        self,
        root: Misc,
        on_result: Callable[[Candidates], None],
        current: Callable[[], str],
    ) -> None:
        """Bind the runner to the Tk root, the result handler and the live text.

        Args:
            root: The gate's Tk root (schedules the poll).
            on_result: Fills the form from the candidates, on the Tk thread.
            current: Returns the description box's text right now.
        """
        self._root = root
        self._on_result = on_result
        self._current = current
        self._result: queue.Queue[Candidates] | None = None
        self._description = ""

    def start(self, description: str) -> bool:
        """Start a lookup; return False, starting nothing, if one is running."""
        if self._result is not None:
            return False
        self._result = start_lookup(lookup_candidates, description)
        self._description = description
        self._root.after(FETCH_POLL_MS, self.poll)
        return True

    def poll(self) -> None:
        """On the Tk thread: hand a finished result over, else poll again."""
        result = self._result
        if result is None:
            return
        try:
            candidates = result.get_nowait()
        except queue.Empty:
            self._root.after(FETCH_POLL_MS, self.poll)
            return
        self._result = None
        if self._current() == self._description:
            self._on_result(candidates)
