#!/usr/bin/env python3
"""Assert that a peer already holds this device's recent food-log entries.

Used by ``phone_deploy.sh``'s pre-install gate. ``adb install -r`` preserves
app data, and the deploy script refuses every path that would not -- but
"preserved" is a property of the happy path. Only a copy on a peer survives a
failed install or a later wipe, and the log is CRDT-synced precisely so such a
copy exists.

The check is deliberately **remote-side**. The obvious device-side signal does
not work: the app records a successful tick through ``SyncHealth``, which
writes to SharedPreferences (app-private, unreadable over ADB on a release
build), and it only writes to logcat when a sync *fails*. Watching logcat for
a success marker would be a gate that can never pass, which is worse than no
gate -- it trains you to ignore it.

So this pulls the shared log and asserts the merged result actually contains
recent entries. It answers "is there a recoverable copy off the device", which
is the question the gate exists to ask.

Exit codes: 0 a peer holds recent state | 1 it does not, or the remote could
not be reached (the caller decides whether that blocks the deploy).
"""

from __future__ import annotations

from datetime import date
import importlib
import logging
import pathlib
import sys

# Running this as `python3 scripts/sync_freshness.py` puts *scripts/* on
# sys.path, not the repo root, so `import diet_guard` fails unless the package
# happens to be installed -- which it is not on a CI runner that only installs
# requirements.txt. Same reason and same fix as `check_patch_targets.py`.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

#: How stale the newest synced entry may be before the gate calls it unproven.
#: Generous: a day with no meals logged yet is normal first thing in the
#: morning, and this must not fail a deploy for an ordinary quiet morning.
_MAX_AGE_DAYS = 3

_logger = logging.getLogger("sync_freshness")


def main() -> int:
    """Pull the shared log and report whether it holds recent entries."""
    # Imported here, after the sys.path fix above and behind the entry point,
    # so the module's own imports stay stdlib-only and lint-clean.
    load_log = importlib.import_module("diet_guard._state").load_log
    now_local = importlib.import_module("diet_guard._state").now_local
    pull_peer_logs = importlib.import_module("diet_guard._sync_refresh").pull_peer_logs

    reason = pull_peer_logs()
    if reason is not None:
        _logger.error("could not pull the shared log: %s", reason)
        return 1

    log = load_log()
    if not log:
        _logger.error("the merged log is empty; no peer holds this device's state")
        return 1

    newest = max(log)
    age = (now_local().date() - date.fromisoformat(newest)).days
    if age > _MAX_AGE_DAYS:
        _logger.error("newest synced day is %s (%dd old)", newest, age)
        return 1

    _logger.info("a peer holds entries through %s (%dd old)", newest, age)
    return 0


if __name__ == "__main__":
    # The caller is a shell gate, so the reason must reach stderr, not vanish.
    logging.basicConfig(level=logging.INFO, format="sync freshness: %(message)s")
    sys.exit(main())
