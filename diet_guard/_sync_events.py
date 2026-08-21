"""Event-driven sync triggers: publish when state changes, not on a clock.

diet_guard used to run a ``diet-guard-sync.timer`` every ~15 min.  That cadence
was a poor proxy for the two moments the shared log actually changes on this
device, and it paid a network round-trip on every idle tick in between:

* **before a lock** -- already handled in :func:`diet_guard._cli_gate._should_lock`,
  which pulls only when a lock is otherwise due, so a meal just logged on the
  phone clears the lock without a manual re-entry.
* **after a meal is logged here** -- this module.  Publishing immediately is
  what stops the *phone* nagging for a slot already logged on the PC; the
  mirror image of the rule in ``CLAUDE.md`` that keeps the phone's tick
  unconditional.

Both go through :func:`~diet_guard._sync.pull_shared_log`, which despite its
name runs a *full* tick (pull, merge, re-sign, persist, push, plus budget and
both food banks) and fails closed -- a sync outage returns a reason string
rather than raising, so it can never turn a successful local log into an error.

The trade this makes explicit: a PC that is on but neither logging nor locking
no longer pulls at all, so an inbound phone edit lands at the next log or lock
rather than within 15 min.  That is bounded by the meal-slot spacing, since a
day that goes unlogged raises a lock by construction.
"""

from __future__ import annotations

from importlib import import_module
import logging
import sys
import threading
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Callable

_logger = logging.getLogger(__name__)


# ``_sync`` pulls in ``crdt_sync`` -> ``requests`` (~78ms), and the gate's
# common path -- no lock due -- never publishes. Deferring the import is what
# lets ``gate --check`` decide without loading an HTTP stack it will not use.
#
# A module-level ``__getattr__`` (PEP 562) rather than a function-local import
# so ``patch.object(_sync_events, "pull_shared_log", ...)`` still resolves.
def __getattr__(name: str) -> object:
    """Resolve the deferred sync import on first attribute access."""
    if name != "pull_shared_log":
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    return import_module("diet_guard._sync").pull_shared_log


def publish_after_log() -> str | None:
    """Run a full sync tick after a local write, swallowing any outage.

    Call this *after* the local log write is durable, never before: the local
    entry is the source of truth for this device, and a network failure must
    leave it intact and the caller's own success path untouched.

    Returns:
        ``None`` when the tick completed, or a short human-readable reason when
        it could not -- callers that have somewhere to show it (the CLI) print
        it; callers that do not (the gate, the MCP tool) let it fall to the log.
    """
    reason = sys.modules[__name__].pull_shared_log()
    if reason is not None:
        _logger.info("post-log sync skipped: %s", reason)
    return reason


def publish_after_log_detached(on_failure: Callable[[str], None]) -> None:
    """Publish on a background thread, returning immediately.

    For the *interactive* CLI, where blocking the terminal is the problem: the
    full tick measures ~15.5s, of which only ~2.5s is the push the phone
    actually needs. The local write is already durable by the time this is
    called, so the worst case is a late publish -- exactly the trade
    :func:`publish_after_log` already documents.

    **Not for the gate.** ``diet-guard-gate.service`` is ``Type=oneshot``, so
    systemd reaps the unit as soon as the main thread exits and a daemon
    thread would be killed mid-push. The gate keeps calling
    :func:`publish_after_log` and waiting for it.

    The thread is non-daemon precisely so the interpreter waits for it at exit:
    the CLI's output is already flushed, so the user sees their result at once
    while the process lingers only as long as the push takes.

    Args:
        on_failure: Called with a reason if the publish could not complete.
            Runs on the worker thread, after the caller has printed and
            returned, so it must not touch the caller's output ordering.
    """

    def _publish() -> None:
        reason = publish_after_log()
        if reason is not None:
            on_failure(reason)

    threading.Thread(target=_publish, daemon=False).start()
