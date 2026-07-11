"""CLI handler for the ``gate`` subcommand.

Split out from :mod:`diet_guard._cli` to keep that module under the repo's
500-line cap (see ``CLAUDE.md``'s "feat: split oversized modules" history).
The gate's actual window logic already lives in ``_gatelock*.py``; this is
just the thin CLI glue, same as ``_cli_sync.py`` is for ``sync``.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from diet_guard._gate import gate_is_due
from diet_guard._gatelock import MealGate, acquire_gate_lock, release_gate_lock
from diet_guard._gatelock_support import wait_for_display
from diet_guard._sync import pull_shared_log

if TYPE_CHECKING:
    from collections.abc import Callable


def _should_lock(emit: Callable[[str], None]) -> bool:
    """Decide whether to lock, pulling from sync first if a lock looks due.

    This wraps the pure, local :func:`~diet_guard._gate.gate_is_due` predicate
    with one network step: the cheap local check runs first, and only when it
    says a lock is due do we pull the shared log (via :func:`pull_shared_log`,
    which fails closed) and re-read the freshly written log.  So a meal just
    logged on the phone can clear the lock, while a not-due tick never touches
    the network at all.
    """
    if not gate_is_due():
        return False
    reason = pull_shared_log()  # only pay the network cost when about to lock
    if reason is not None:
        emit(f"{reason}; using local log.")
    return gate_is_due()


def cmd_gate(emit: Callable[[str], None], *, check: bool, demo: bool) -> int:
    """Run the log-to-unlock gate.

    Three modes: ``--check`` is a headless decision (no window) whose exit code
    a timer reads; ``--demo`` always shows a safe demo window; bare ``gate``
    shows the real lock only when one is due.  Both real modes route through
    :func:`_should_lock`, which -- only when a lock is otherwise due -- pulls
    the shared log first (via :func:`pull_shared_log`) so a meal just logged on
    the phone unlocks without a manual re-entry.  A flock guard stops a second
    window from stacking on top of the first, and a window-opening mode first
    waits for the X display so a session-start launch never crashes unshown.

    Args:
        emit: A one-line output sink (``_cli._emit``, passed in rather than
            imported -- see ``_cli_sync.cmd_sync`` for why).
        check: Headless mode -- print and return an exit code, open no window.
        demo: Use safe demo mode (local grab + close button) for the window.

    Returns:
        For ``--check``: 0 if not due, 1 if a lock is due.  Otherwise 0.
    """
    if check:
        due = _should_lock(emit)
        emit("due (a lock is warranted)" if due else "ok (no lock needed)")
        return 1 if due else 0
    if not demo and not _should_lock(emit):
        emit("ok - no lock needed right now.")
        return 0
    handle = acquire_gate_lock()
    if handle is None:
        emit("the gate is already running.")
        return 0
    try:
        # At session start the timer can fire before the X display/auth cookie
        # is ready; wait it out so the window opens instead of crashing on a
        # "couldn't connect to display" TclError (see _gatelock.wait_for_display).
        if not wait_for_display():
            emit("display not ready yet; will retry on the next timer tick.")
            return 0
        MealGate(demo_mode=demo).run()
    finally:
        release_gate_lock(handle)
    return 0
