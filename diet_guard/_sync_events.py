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

import logging

from diet_guard._sync import pull_shared_log

_logger = logging.getLogger(__name__)


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
    reason = pull_shared_log()
    if reason is not None:
        _logger.info("post-log sync skipped: %s", reason)
    return reason
