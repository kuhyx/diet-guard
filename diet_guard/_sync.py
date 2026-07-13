"""Cross-device log sync orchestration for diet_guard.

Pulls every other device's pushed log from GitHub-backed dumb storage
(``crdt_sync.GitHubSyncClient``), merges with the local log via
``crdt_sync``'s shared CRDT scheme (:mod:`diet_guard._sync_merge` adapts
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

from crdt_sync import GitHubSyncClient, GitHubSyncError, Log, merge_logs

from diet_guard._budget import read_raw_record, write_raw_record
from diet_guard._constants import (
    SYNC_DEVICE_ID,
    SYNC_REPO_NAME,
    SYNC_REPO_OWNER,
    SYNC_TIMEOUT_SECONDS,
    SYNC_TOKEN_FILE,
)
from diet_guard._foodbank import rebuild_food_bank
from diet_guard._state import DayLog, read_raw_log, resign_entry, write_raw_log
from diet_guard._sync_merge import (
    budget_to_log,
    daylog_to_log,
    log_to_budget,
    log_to_daylog,
    parse_remote_budget,
    parse_remote_log,
)

_logger = logging.getLogger(__name__)

_DEVICES_DIR = "diet-guard-sync/devices"


class SyncError(Exception):
    """Raised when a sync run cannot even start (no usable PAT)."""


def _device_log_path(device_id: str) -> str:
    """Return the repo-relative path a device's full log is pushed to."""
    return f"{_DEVICES_DIR}/{device_id}/food_log.json"


def _device_budget_path(device_id: str) -> str:
    """Return the repo-relative path a device's budget is pushed to."""
    return f"{_DEVICES_DIR}/{device_id}/budget.json"


def _read_token() -> str:
    """Return the saved sync PAT, stripped of trailing whitespace.

    Raises:
        SyncError: If the token file is missing or empty -- the user has not
            completed the one-time github.com setup step yet.
    """
    if not SYNC_TOKEN_FILE.exists():
        message = (
            f"no sync token at {SYNC_TOKEN_FILE} -- create a fine-grained "
            "GitHub PAT scoped to the syncs repo's contents and "
            f"save it there (mode 600), then re-run sync"
        )
        raise SyncError(message)
    token = SYNC_TOKEN_FILE.read_text().strip()
    if not token:
        msg = f"{SYNC_TOKEN_FILE} is empty"
        raise SyncError(msg)
    return token


def _pull_remote_logs(client: GitHubSyncClient) -> list[Log]:
    """Return every other device's last-pushed log, skipping this one.

    A device whose pushed file is corrupt, truncated, or otherwise
    unparsable (new or old wire format) is logged and skipped, same as one
    that has never pushed at all -- GitHub is an external system boundary,
    and one bad device's file must not stall merging in every other
    device's.
    """
    remote_logs: list[Log] = []
    for device_id in client.list_directory(_DEVICES_DIR):
        if device_id == SYNC_DEVICE_ID:
            continue
        text = client.get_file_text(_device_log_path(device_id))
        if text is None:
            continue
        try:
            remote_logs.append(parse_remote_log(text))
        except (TypeError, KeyError, ValueError, json.JSONDecodeError):
            _logger.warning("Unparsable log pushed by device %r, skipping", device_id)
    return remote_logs


def _sync_budget(client: GitHubSyncClient) -> None:
    """Pull other devices' budgets, merge, write locally, push this device's.

    Runs in the same tick as the food-log sync, reusing the already
    authenticated ``client``. Merging is last-writer-wins by edit time (see
    :mod:`diet_guard._sync_merge`'s budget adapters), not the food log's
    union-of-immutable-entries -- a budget can be edited repeatedly. A
    device that has never run ``init`` neither contributes a local record
    to the merge nor overwrites a real budget pulled from elsewhere, and if
    *no* device has ever set one, nothing is written or pushed.
    """
    merged = budget_to_log(read_raw_record())
    for device_id in client.list_directory(_DEVICES_DIR):
        if device_id == SYNC_DEVICE_ID:
            continue
        text = client.get_file_text(_device_budget_path(device_id))
        if text is None:
            continue
        try:
            merged = merge_logs(merged, parse_remote_budget(text))
        except (TypeError, KeyError, ValueError, json.JSONDecodeError):
            _logger.warning(
                "Unparsable budget pushed by device %r, skipping",
                device_id,
            )

    merged_record = log_to_budget(merged)
    if merged_record is None:
        return
    write_raw_record(merged_record)

    push_json = json.dumps(
        {record_id: record.to_dict() for record_id, record in merged.items()},
        indent=2,
    )
    client.put_file_text(
        _device_budget_path(SYNC_DEVICE_ID),
        push_json,
        message="diet_guard sync",
    )


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
        SyncError: If the local PAT is missing or empty.
        crdt_sync.GitHubSyncError: Propagated from the GitHub client for any
            transport failure -- the caller (CLI/timer) decides how to
            report it.
    """
    token = _read_token()
    client = GitHubSyncClient(
        SYNC_REPO_OWNER, SYNC_REPO_NAME, token, timeout_seconds=SYNC_TIMEOUT_SECONDS
    )

    merged = daylog_to_log(read_raw_log())
    for remote_log in _pull_remote_logs(client):
        merged = merge_logs(merged, remote_log)

    merged_daylog = log_to_daylog(merged)
    resigned: DayLog = {
        day: [resign_entry(entry) for entry in entries]
        for day, entries in merged_daylog.items()
    }
    write_raw_log(resigned)
    rebuild_food_bank(resigned)
    _sync_budget(client)

    push_log = daylog_to_log(resigned)
    push_json = json.dumps(
        {record_id: record.to_dict() for record_id, record in push_log.items()},
        indent=2,
    )
    client.put_file_text(
        _device_log_path(SYNC_DEVICE_ID),
        push_json,
        message="diet_guard sync",
    )
    return resigned


def pull_shared_log() -> str | None:
    """Run a sync tick, failing closed instead of raising.

    A thin wrapper over :func:`run_sync` for callers that must never crash on a
    sync error: the gate's automatic pre-lock refresh and the lock screen's
    manual "Fetch from sync" button.  Returns ``None`` on success, or a short
    human-readable reason when the pull could not complete, so the caller keeps
    its own lock decision rather than failing open.

    The three caught types are the whole realistic failure surface of a run:
    :class:`SyncError` (no/empty token), :class:`~crdt_sync.GitHubSyncError`
    (the client wraps every ``requests`` transport error in this), and
    :class:`OSError` (reading the token or writing the merged log back). A bug
    outside these is deliberately *not* swallowed -- it should surface, not be
    silently reported as a sync outage.
    """
    try:
        run_sync()
    except (SyncError, GitHubSyncError, OSError) as exc:
        return f"sync unavailable ({exc})"
    return None
