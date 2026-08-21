"""Cross-device log sync orchestration for diet_guard.

Pulls every other device's pushed log from GitHub-backed dumb storage
(``crdt_sync.GitHubSyncClient``), merges with the local log via
``crdt_sync``'s shared CRDT scheme (:mod:`diet_guard.sync_merge` adapts
diet_guard's entries to/from ``crdt_sync.Record``), re-signs every persisted
entry, rebuilds the food bank, and pushes this device's own merged log back
up in the new Record-based wire format.

The daily budget syncs alongside the food log in the same tick (see
:func:`_sync_budget`, called from :func:`run_sync`): a sibling
``budget.json`` per device, merged the same way but last-writer-wins per
edit rather than union-of-immutable-entries, since a budget (unlike a
food-log entry) can be edited repeatedly.
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING

from crdt_sync import (
    DeviceIdentity,
    FileSyncStateStore,
    GitHubSyncError,
    Log,
    RemoteStore,
    RemoteSyncError,
    SyncState,
    merge_logs,
    revision_of,
)

from diet_guard._constants import (
    SYNC_STATE_FILE,
)
from diet_guard._device import device_identity
from diet_guard._foodbank_rebuild import rebuild_food_bank
from diet_guard._state_sync import (
    read_raw_log,
    resign_entry,
    write_raw_log,
)
from diet_guard._sync_banks import _sync_budget, _sync_food_bank, _sync_manual_bank
from diet_guard._sync_client import _client_for_run
from diet_guard._sync_errors import SyncError
from diet_guard._sync_paths import _DEVICES_DIR, _REVS_DIR, _device_log_path
from diet_guard.sync_merge import (
    daylog_to_log,
    log_to_daylog,
    parse_remote_log,
)

if TYPE_CHECKING:
    from collections.abc import Sequence

    from diet_guard._state import (
        DayLog,
    )

_logger = logging.getLogger(__name__)

# One small text node per device, each written only by its owner. Deliberately
# not one shared map: a whole-map write would erase every other device's entry,
# after which those peers would look permanently unchanged and never be


def _remote_revisions(client: RemoteStore) -> dict[str, str]:
    """Return every peer's published food-log revision, cheaply where possible.

    Degrades to an empty map -- meaning "fetch everything", the old behaviour
    -- on a backend without a bulk-map read, so correctness never depends on
    the optimisation being available.
    """
    get_string_map = getattr(client, "get_string_map", None)
    if get_string_map is None:
        return {}
    try:
        return get_string_map(_REVS_DIR)
    except (GitHubSyncError, RemoteSyncError):
        # A revision map that cannot be read is not worth failing a sync
        # over; without it every peer is simply fetched, as before.
        return {}


def _pull_remote_logs(
    client: RemoteStore,
    remote_revs: dict[str, str],
    state: SyncState,
    *,
    identity: DeviceIdentity,
    device_ids: Sequence[str],
) -> tuple[list[Log], dict[str, str]]:
    """Return every other device's last-pushed log, plus the revisions seen.

    A device whose pushed file is corrupt, truncated, or otherwise
    unparsable (new or old wire format) is logged and skipped, same as one
    that has never pushed at all -- GitHub is an external system boundary,
    and one bad device's file must not stall merging in every other
    device's.

    A peer whose published revision matches the one already merged is skipped
    without downloading it at all. This is the single largest traffic saving
    in the fleet: these logs are hundreds of KB and this timer runs 96 times a
    day, so re-reading an unchanged peer is pure waste.
    """
    remote_logs: list[Log] = []
    seen_revs: dict[str, str] = {}
    for device_id in device_ids:
        if identity.is_own(device_id):
            continue
        remote_rev = remote_revs.get(device_id)
        if remote_rev is not None and remote_rev == state.peer_revs.get(device_id):
            # Already merged, and that merge is in the local log. Carry the
            # revision forward so it stays skipped next tick.
            seen_revs[device_id] = remote_rev
            continue
        text = client.get_file_text(_device_log_path(device_id))
        if text is None:
            continue
        try:
            remote_logs.append(parse_remote_log(text))
        except (TypeError, KeyError, ValueError, json.JSONDecodeError):
            # Deliberately not recorded as seen: a corrupt push must be
            # retried next tick, not remembered as merged.
            _logger.warning("Unparsable log pushed by device %r, skipping", device_id)
            continue
        seen_revs[device_id] = remote_rev or revision_of(text)
    return remote_logs, seen_revs


def run_sync() -> DayLog:
    """Run one full sync tick: pull, merge, re-sign, persist, push.

    Every persisted entry is re-signed regardless of origin (not just
    phone-origin ones): a signature computed on another device cannot be
    trusted as this device's shared key sees it, and an inbound entry with no
    signature at all would otherwise be silently dropped on the very next
    read by :func:`diet_guard._state.load_log`. The daily budget syncs in
    the same tick (see :func:`_sync_budget`), reusing this same client.

    Returns:
        The merged log as it now sits on disk locally, post re-sign.

    Raises:
        SyncError: If *neither* backend is configured -- no Firebase config and
            no usable PAT.
        crdt_sync.RemoteSyncError: Propagated from whichever backend failed for
            any transport failure -- the caller (CLI/timer) decides how to
            report it.
    """
    client = _client_for_run()

    identity = device_identity()
    state_store = FileSyncStateStore(SYNC_STATE_FILE)
    state = state_store.load()
    remote_revs = _remote_revisions(client)
    device_ids = list(client.list_directory(_DEVICES_DIR))

    merged = daylog_to_log(read_raw_log())
    remote_logs, seen_revs = _pull_remote_logs(
        client,
        remote_revs,
        state,
        identity=identity,
        device_ids=device_ids,
    )
    for remote_log in remote_logs:
        merged = merge_logs(merged, remote_log)

    merged_daylog = log_to_daylog(merged)
    resigned: DayLog = {
        day: [resign_entry(entry) for entry in entries]
        for day, entries in merged_daylog.items()
    }
    write_raw_log(resigned)
    rebuild_food_bank(resigned)
    _sync_budget(client, device_ids)
    _sync_food_bank(client, device_ids)
    _sync_manual_bank(client, device_ids)

    push_log = daylog_to_log(resigned)
    push_json = json.dumps(
        {record_id: record.to_dict() for record_id, record in push_log.items()},
        indent=2,
    )
    revision = revision_of(push_json)
    if revision != state.pushed_rev:
        client.put_file_text(
            _device_log_path(identity.device_id),
            push_json,
            message="diet_guard sync",
        )
        # Published after the log, never before: a peer that cached "seen rev
        # X" against a log it never received would skip it forever.
        client.put_file_text(
            f"{_REVS_DIR}/{identity.device_id}",
            revision,
            message="diet_guard sync: revision",
        )
    state_store.save(SyncState(pushed_rev=revision, peer_revs=seen_revs))
    return resigned


def pull_shared_log() -> str | None:
    """Run a sync tick, failing closed instead of raising.

    A thin wrapper over :func:`run_sync` for callers that must never crash on a
    sync error: the gate's automatic pre-lock refresh and the lock screen's
    manual "Fetch from sync" button.  Returns ``None`` on success, or a short
    human-readable reason when the pull could not complete, so the caller keeps
    its own lock decision rather than failing open.

    The three caught types are the whole realistic failure surface of a run:
    :class:`SyncError` (no/empty token), :class:`~crdt_sync.RemoteSyncError`
    (the shared base of every backend's transport/auth failure), and
    :class:`OSError` (reading the token or writing the merged log back). A bug
    outside these is deliberately *not* swallowed -- it should surface, not be
    silently reported as a sync outage.

    ``RemoteSyncError``, **not** ``GitHubSyncError``: since Firebase became the
    primary backend, ``FirebaseSyncError``/``FirebaseAuthError`` are *siblings*
    of ``GitHubSyncError`` under ``RemoteSyncError``, not subclasses. Catching
    the GitHub type alone let every per-request Firebase failure escape, so
    this fail-closed helper raised a traceback out of the gate's "Fetch from
    sync" button instead of returning a reason and leaving the lock up.
    """
    try:
        run_sync()
    except (SyncError, RemoteSyncError, OSError) as exc:
        return f"sync unavailable ({exc})"
    return None
