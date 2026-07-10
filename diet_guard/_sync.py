"""Cross-device log sync orchestration for diet_guard.

Pulls every other device's pushed log from GitHub-backed dumb storage
(:mod:`diet_guard._sync_github`), merges with the local log
(:mod:`diet_guard._sync_merge`), re-signs every persisted entry, rebuilds the
food bank, and pushes this device's own merged log back up.
"""

from __future__ import annotations

import json
import logging

from diet_guard._constants import (
    SYNC_DEVICE_ID,
    SYNC_REPO_NAME,
    SYNC_REPO_OWNER,
    SYNC_TOKEN_FILE,
)
from diet_guard._foodbank import rebuild_food_bank
from diet_guard._state import DayLog, read_raw_log, resign_entry, write_raw_log
from diet_guard._sync_github import GitHubSyncClient
from diet_guard._sync_merge import merge_logs

_logger = logging.getLogger(__name__)

_DEVICES_DIR = "diet-guard-sync/devices"


class SyncError(Exception):
    """Raised when a sync run cannot even start (no usable PAT)."""


def _device_log_path(device_id: str) -> str:
    """Return the repo-relative path a device's full log is pushed to."""
    return f"{_DEVICES_DIR}/{device_id}/food_log.json"


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


def _pull_remote_logs(client: GitHubSyncClient) -> list[DayLog]:
    """Return every other device's last-pushed log, skipping this one.

    A device whose pushed file is corrupt or truncated (e.g. an interrupted
    push) is logged and skipped, same as one that has never pushed at all --
    GitHub is an external system boundary, and one bad device's file must
    not stall merging in every other device's.
    """
    remote_logs: list[DayLog] = []
    for device_id in client.list_directory(_DEVICES_DIR):
        if device_id == SYNC_DEVICE_ID:
            continue
        text = client.get_file_text(_device_log_path(device_id))
        if text is None:
            continue
        try:
            remote_log = json.loads(text)
        except json.JSONDecodeError:
            _logger.warning("Unparsable log pushed by device %r, skipping", device_id)
            continue
        if isinstance(remote_log, dict):
            remote_logs.append(remote_log)
    return remote_logs


def run_sync() -> DayLog:
    """Run one full sync tick: pull, merge, re-sign, persist, push.

    Every persisted entry is re-signed regardless of origin (not just
    phone-origin ones): a signature computed on another device cannot be
    trusted as this device's shared key sees it, and an inbound entry with no
    signature at all would otherwise be silently dropped on the very next
    read by :func:`diet_guard._state.load_log`.

    Returns:
        The merged log as it now sits on disk locally, post re-sign.

    Raises:
        SyncError: If the local PAT is missing or empty.
        diet_guard._sync_github.GitHubSyncError: Propagated from the GitHub
            client for any transport failure -- the caller (CLI/timer)
            decides how to report it.
    """
    token = _read_token()
    client = GitHubSyncClient(SYNC_REPO_OWNER, SYNC_REPO_NAME, token)

    merged = read_raw_log()
    for remote_log in _pull_remote_logs(client):
        merged = merge_logs(merged, remote_log)

    resigned: DayLog = {
        day: [resign_entry(entry) for entry in entries]
        for day, entries in merged.items()
    }
    write_raw_log(resigned)
    rebuild_food_bank(resigned)

    client.put_file_text(
        _device_log_path(SYNC_DEVICE_ID),
        json.dumps(resigned, indent=2),
        message="diet_guard sync",
    )
    return resigned
