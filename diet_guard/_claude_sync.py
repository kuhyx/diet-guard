"""The relay worker's two sync touch points, behind one module seam.

* :func:`pull_peers` runs before a request is served, so the due slot is
  computed from a log that already holds what the phone logged. It is the
  narrow pull (``_sync_refresh.pull_peer_logs``, ~84 ms), not a full tick.
* :func:`publish` runs after the answer is written: a full tick (15 to 27 s)
  that must never sit in front of the answer (``docs/DOCS-claude-relay.md``
  section 5).

Both return ``None`` on success or a short reason, never raise on an outage
(fail closed: the worker leaves the request pending on a failed pull).
``conftest`` patches both names here, so a test that logs through the worker
cannot reach the real remote.
"""

from __future__ import annotations

from diet_guard import _sync_events, _sync_refresh


def pull_peers() -> str | None:
    """Pull every peer's log; None on success, else why not."""
    return _sync_refresh.pull_peer_logs()


def publish() -> str | None:
    """Run a full sync tick after a write; None on success, else why not."""
    return _sync_events.publish_after_log()
