"""Off-thread plumbing for the lock screen's "Fetch from sync" button.

Split out of :mod:`._gatelock_mealflow`, which is already near the repo's
250-line cap.

The pull used to run on the Tk thread, so the fullscreen lock froze for the
whole tick -- measured at ~18-27s against the live remote, and unbounded in
the worst case because the Firebase client's default timeout is 15s *per
request*. A user staring at a dead window is exactly the experience the gate
must not create.

Two rules shape the design:

* **The worker touches no widget.** Tcl is not thread-safe, and that includes
  ``after`` -- so the worker only ``put``s its result on a queue, and a poll
  scheduled on the Tk thread picks it up. That also makes the completion path
  testable with no thread at all: put a result, call the poll, assert.
* **The worker does not write the log either.** :func:`pull_shared_log`
  persists the merged result, so running it while the user types would let a
  merge snapshot taken *before* their meal was entered land *after* it,
  silently dropping the entry. The button is therefore disabled for the
  duration, which is both the race fix and the reentrancy guard.
"""

from __future__ import annotations

import queue
import threading
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

#: How often the Tk thread checks whether the worker has finished.
FETCH_POLL_MS = 50


def start_fetch(pull: Callable[[], str | None]) -> queue.Queue[str | None]:
    """Run ``pull`` on a daemon thread; return the queue its result lands on.

    Daemon so a hung request can never keep the process alive after the window
    is gone -- the gate is a ``Type=oneshot`` unit and must exit.
    """
    result: queue.Queue[str | None] = queue.Queue(maxsize=1)

    def _worker() -> None:
        """Runs OFF the Tk thread. Touches no widget, by construction."""
        reason: str | None = "sync failed (unexpected error)"
        try:
            reason = pull()
        finally:
            # Always feed the queue, even if ``pull`` raised: this thread has
            # nowhere to propagate to, so an escaping exception would leave the
            # poll waiting forever with the button disabled and the user stuck.
            # ``pull`` is already fail-closed, so this is the unexpected case.
            result.put(reason)

    threading.Thread(target=_worker, daemon=True).start()
    return result
