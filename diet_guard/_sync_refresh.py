"""The gate's narrow, pre-lock refresh: peer logs only, no push.

``_sync.run_sync`` is the *full* tick -- peer logs, the budget, both food
banks, a rebuild and a push. That is the right thing to run after a meal is
logged, and it is what :func:`~diet_guard._sync_events.publish_after_log`
still does. It is the wrong thing to run *in front of a fullscreen lock*: the
banks alone measured ~21s against the live remote (the curated bank is absent
on Firebase for every peer, so each of ~21 peers fell through to a GitHub
round trip that returned ``{}``), and the budget loop another ~2.6s.

The gate has exactly one question to answer -- *"has a peer already logged
this slot?"* -- and only the peer **logs** can answer it. So this module does
that and nothing else:

* one bulk read of the revision map (~83ms, a single request),
* a fetch of only those peers whose revision actually moved,
* merge, re-sign, write.

No budget, no banks, no ``rebuild_food_bank``, and **no push**. The full tick
still runs after the window closes, so nothing is permanently skipped -- the
exhaustive pass is merely moved off the path the user waits on.

**Accepted trade:** a budget edited on the phone is not visible in the lock
window's dashboard until that post-window tick. It cannot affect the lock
*decision*, which is why it is safe to defer, but it is user-visible and so
recorded here rather than left implicit.
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING

from crdt_sync import (
    FileSyncStateStore,
    Log,
    RemoteSyncError,
    SyncState,
    merge_logs,
    revision_of,
)

from diet_guard import _sync
from diet_guard._device import device_identity
from diet_guard._state_sync import read_raw_log, resign_entry, write_raw_log
from diet_guard._sync import _remote_revisions
from diet_guard._sync_client import _client_for_run
from diet_guard._sync_errors import SyncError
from diet_guard._sync_paths import _DEVICES_DIR, _device_log_path
from diet_guard.sync_merge import daylog_to_log, log_to_daylog, parse_remote_log

if TYPE_CHECKING:
    from crdt_sync import RemoteStore

_logger = logging.getLogger(__name__)


def _candidate_peers(
    client: RemoteStore,
    remote_revs: dict[str, str],
    state: SyncState,
) -> list[str]:
    """Return the device ids worth considering, without a directory listing.

    ``list_directory`` is the single most expensive call in a tick (~445ms,
    because the mirrored GitHub half alone is ~360ms), and the revision map
    already names every peer that has ever published one. Union it with the
    peers we have merged before so a device that stopped publishing revisions
    is still reachable.

    Falls back to the real listing when the revision map is empty -- a
    GitHub-only device has no ``get_string_map``, and there "no revisions"
    means "no information", not "no peers".
    """
    if not remote_revs:
        return list(client.list_directory(_DEVICES_DIR))
    return sorted(set(remote_revs) | set(state.peer_revs))


def _peer_is_current(
    device_id: str,
    remote_revs: dict[str, str],
    state: SyncState,
) -> bool:
    """Return True when ``device_id`` holds nothing this device has not merged.

    Two ways to be current, and the second is specific to this narrow pass:

    * the peer publishes a revision equal to the one already merged, or
    * the peer publishes **no** revision but has been merged before.

    The second rule is what removes the standing ~1.25s cost of the frozen
    legacy role-id directories, which can never satisfy the first. It is sound
    only because this pass is *not* the authoritative one: the post-window full
    tick still reads every peer exhaustively, and a union CRDT cannot lose a
    record that arrives a tick later.

    Membership is tested with ``in``, never ``.get(...) is not None`` --
    ``peer_revs`` legitimately holds explicit null values, and treating those
    as "never seen" would re-download them on every single tick forever.
    """
    remote_rev = remote_revs.get(device_id)
    if remote_rev is None:
        return device_id in state.peer_revs
    return remote_rev == state.peer_revs.get(device_id)


def _merge_peer_logs(
    client: RemoteStore,
    peers: list[str],
    remote_revs: dict[str, str],
    merged: Log,
    seen: dict[str, str],
) -> tuple[Log, bool]:
    """Merge each peer's pushed log into ``merged``; report whether any landed."""
    changed = False
    for device_id in peers:
        text = client.get_file_text(_device_log_path(device_id))
        if text is None:
            continue
        try:
            merged = merge_logs(merged, parse_remote_log(text))
        except (TypeError, KeyError, ValueError, json.JSONDecodeError):
            # A corrupt push must be retried next tick, not remembered as
            # merged -- so deliberately not recorded in ``seen``.
            _logger.warning("Unparsable log pushed by device %r, skipping", device_id)
            continue
        seen[device_id] = remote_revs.get(device_id) or revision_of(text)
        changed = True
    return merged, changed


def refresh_peer_logs() -> None:
    """Merge any newly-published peer log into the local one.

    Raises:
        SyncError: If no backend is configured.
        crdt_sync.RemoteSyncError: On any transport failure.
    """
    client = _client_for_run()
    identity = device_identity()
    # Via the module, not a direct import: the suite redirects
    # ``_sync.SYNC_STATE_FILE`` to a tmp path, and a private copy of the
    # constant would escape that redirect and write real user state.
    state_store = FileSyncStateStore(_sync.SYNC_STATE_FILE)
    state = state_store.load()
    remote_revs = _remote_revisions(client)

    peers = [
        device_id
        for device_id in _candidate_peers(client, remote_revs, state)
        if not identity.is_own(device_id)
        and not _peer_is_current(device_id, remote_revs, state)
    ]
    if not peers:
        return

    seen: dict[str, str] = {}
    merged, changed = _merge_peer_logs(
        client, peers, remote_revs, daylog_to_log(read_raw_log()), seen
    )
    if not changed:
        return

    # Re-sign every entry, not just the newly arrived ones: a signature made on
    # another device is not valid under this device's key, and ``load_log``
    # drops unsigned entries outright -- that is how a phone-logged meal would
    # vanish on the very next read.
    resigned = {
        day: [resign_entry(entry) for entry in entries]
        for day, entries in log_to_daylog(merged).items()
    }
    # Log first, state second. If the state landed and this write failed, a peer
    # would be recorded as merged while its records were absent -- silent loss.
    write_raw_log(resigned)
    # ``pushed_rev`` verbatim: this pass never pushes, and overwriting it would
    # convince the next full tick it had already published, silently making this
    # device invisible to every peer. ``peer_revs`` merged, not replaced: only
    # changed peers were visited, so a wholesale replace would drop the ~20
    # untouched entries and re-download all of them next tick.
    state_store.save(
        SyncState(
            pushed_rev=state.pushed_rev,
            peer_revs={**state.peer_revs, **seen},
        )
    )


def pull_peer_logs() -> str | None:
    """Run :func:`refresh_peer_logs`, failing closed instead of raising.

    Mirrors :func:`diet_guard._sync.pull_shared_log`'s contract exactly --
    ``None`` on success, a short human-readable reason otherwise -- so the gate
    keeps its own local lock decision rather than failing open on an outage.
    """
    try:
        refresh_peer_logs()
    except (SyncError, RemoteSyncError, OSError) as exc:
        return f"sync unavailable ({exc})"
    return None
