"""CLI handler for the ``gate`` subcommand.

Split out from :mod:`diet_guard._cli` to keep that module under the repo's
500-line cap (see ``CLAUDE.md``'s "feat: split oversized modules" history).
The gate's actual window logic already lives in ``_gatelock*.py``; this is
just the thin CLI glue, same as ``_cli_sync.py`` is for ``sync``.
"""

from __future__ import annotations

from importlib import import_module
import sys
from typing import TYPE_CHECKING

from diet_guard._gate import gate_is_due
from diet_guard._gatelock_lockfile import acquire_gate_lock, release_gate_lock
from diet_guard._gatelock_support import wait_for_display
from diet_guard._sync_events import publish_after_log

if TYPE_CHECKING:
    from collections.abc import Callable

# Names resolved lazily below. Importing ``_gatelock`` eagerly costs ~120ms:
# it reaches ``_resolve`` -> ``_estimator_off`` -> ``requests`` (~78ms) on top
# of tkinter. The common gate tick is *not due* and opens no window, so it must
# not pay for a GUI and an HTTP stack it never touches.
#
# A module-level ``__getattr__`` (PEP 562) rather than a function-local import
# because seven tests do ``patch.object(_cli_gate, "MealGate", ...)`` and
# ``scripts/check_patch_targets.py`` resolves targets with ``hasattr`` -- both
# go through ``__getattr__`` and keep working, while a function-local import
# would make the attribute invisible to both.
_LAZY_ATTRS = {
    "MealGate": ("diet_guard._gatelock", "MealGate"),
    # ``_sync_refresh`` reaches ``crdt_sync`` -> ``requests``; the not-due
    # tick never pulls, so it must not pay that import either.
    "pull_peer_logs": ("diet_guard._sync_refresh", "pull_peer_logs"),
}


def __getattr__(name: str) -> object:
    """Resolve the deferred GUI import on first attribute access."""
    target = _LAZY_ATTRS.get(name)
    if target is None:
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    module_name, attr = target
    return getattr(import_module(module_name), attr)


def _should_lock(emit: Callable[[str], None]) -> bool:
    """Decide whether to lock, pulling from sync first if a lock looks due.

    This wraps the pure, local :func:`~diet_guard._gate.gate_is_due` predicate
    with one network step: the cheap local check runs first, and only when it
    says a lock is due do we pull (via :func:`pull_peer_logs`, which fails
    closed) and re-read the freshly written log.  So a meal just logged on the
    phone can clear the lock, while a not-due tick never touches the network
    at all.

    The pull is deliberately the *narrow* one -- peer logs only, no budget, no
    food banks, no push.  The full tick measured ~21s against the live remote,
    which is not something to sit in front of a fullscreen lock; it still runs
    in :func:`cmd_gate` once the window has closed.  Only the peer logs can
    answer "has a peer already logged this slot?", which is the sole question
    this predicate asks.
    """
    if not gate_is_due():
        return False
    # Through the module object so the lazy hook above resolves it, and so a
    # test's ``patch.object`` still wins.
    reason = sys.modules[__name__].pull_peer_logs()
    if reason is not None:
        emit(f"{reason}; using local log.")
    return gate_is_due()


def cmd_gate(emit: Callable[[str], None], *, check: bool, demo: bool) -> int:
    """Run the log-to-unlock gate.

    Three modes: ``--check`` is a headless decision (no window) whose exit code
    a timer reads; ``--demo`` always shows a safe demo window; bare ``gate``
    shows the real lock only when one is due.  Both real modes route through
    :func:`_should_lock`, which -- only when a lock is otherwise due -- pulls
    the shared log first (via :func:`pull_peer_logs`) so a meal just logged on
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
        # Via the module object, not a bare name: ``MealGate`` is resolved by
        # the lazy ``__getattr__`` above, and a test's ``patch.object`` sets a
        # real module attribute that must win over it.
        sys.modules[__name__].MealGate(demo_mode=demo).run()
    finally:
        release_gate_lock(handle)
    # Publish only once ``run()`` has returned -- i.e. the mainloop has ended and
    # the window is gone. Deliberately NOT inside the unlock handler: that runs
    # on the Tk thread with the lock still up, so a slow or hanging network call
    # would keep the user locked in behind a successful log. Here the worst case
    # is a late publish. One call site covers every unlock reason, including the
    # "Synced from another device" path, which hooking the log itself would miss.
    reason = publish_after_log()
    if reason is not None:
        emit(f"logged locally, not yet published ({reason}).")
    return 0
