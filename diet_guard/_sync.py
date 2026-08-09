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

from crdt_sync import (
    CONFIG_FILE,
    ConfigError,
    DeviceIdentity,
    FileSyncStateStore,
    FirebaseAuthError,
    GitHubSyncClient,
    GitHubSyncError,
    Log,
    RemoteStore,
    RemoteSyncError,
    SyncState,
    merge_logs,
    mirror_client_for,
    revision_of,
)

from diet_guard._budget import read_raw_record, write_raw_record
from diet_guard._budget_history import (
    history_to_json,
    load_entries,
    write_raw_history,
)
from diet_guard._constants import (
    SYNC_REPO_NAME,
    SYNC_REPO_OWNER,
    SYNC_STATE_FILE,
    SYNC_TIMEOUT_SECONDS,
    SYNC_TOKEN_FILE,
)
from diet_guard._device import device_identity
from diet_guard._foodbank import read_food_bank, rebuild_food_bank, write_food_bank
from diet_guard._foodbank_manual import read_manual_bank, write_manual_bank
from diet_guard._state import DayLog, read_raw_log, resign_entry, write_raw_log
from diet_guard._sync_merge import (
    budget_to_log,
    daylog_to_log,
    food_bank_to_log,
    log_to_budget,
    log_to_daylog,
    log_to_food_bank,
    log_to_history,
    log_to_manual_bank,
    manual_bank_to_log,
    parse_remote_budget,
    parse_remote_food_bank,
    parse_remote_log,
    parse_remote_manual_bank,
)

_logger = logging.getLogger(__name__)

_DEVICES_DIR = "diet-guard-sync/devices"
# One small text node per device, each written only by its owner. Deliberately
# not one shared map: a whole-map write would erase every other device's entry,
# after which those peers would look permanently unchanged and never be
# fetched again.
_REVS_DIR = "diet-guard-sync/revs"


class SyncError(Exception):
    """Raised when a sync run cannot even start (no usable PAT)."""


def _remote_client(github: GitHubSyncClient) -> RemoteStore:
    """Return the backend to sync against.

    Firebase when ``~/.config/crdt-sync/`` is set up, with GitHub kept as a
    mirror so a device that has not moved yet still converges; GitHub alone
    otherwise. An unconfigured machine keeps syncing exactly as before.

    Every sub-sync here (log, budget, food bank, manual bank) takes the client
    as a parameter, so this one swap covers all of them.

    The config file is checked before constructing anything, so an
    unconfigured machine never reaches the network -- otherwise a suite that
    blocks real sockets fails here rather than in the code under test.

    Rolling back is deleting this function and passing ``github`` straight
    through: no data moves either way.
    """
    if not CONFIG_FILE.is_file():
        return github
    try:
        return mirror_client_for("diet_guard", github)
    except (ConfigError, FirebaseAuthError, RemoteSyncError) as exc:
        _logger.warning("Firebase unavailable, syncing via GitHub only: %s", exc)
        return github


def _device_log_path(device_id: str) -> str:
    """Return the repo-relative path a device's full log is pushed to."""
    return f"{_DEVICES_DIR}/{device_id}/food_log.json"


def _device_food_bank_path(device_id: str) -> str:
    """Return one device's pushed derived-food-bank path."""
    return f"{_DEVICES_DIR}/{device_id}/food_bank.json"


def _device_manual_bank_path(device_id: str) -> str:
    """Return one device's pushed curated-food-bank path."""
    return f"{_DEVICES_DIR}/{device_id}/food_bank_manual.json"


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
    seen_revs: dict[str, str],
    identity: DeviceIdentity,
) -> list[Log]:
    """Return every other device's last-pushed log, skipping this one.

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
    for device_id in client.list_directory(_DEVICES_DIR):
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
    return remote_logs


def _sync_food_bank(client: GitHubSyncClient) -> None:
    """Pull, merge, persist and push the log-derived food bank.

    Runs *after* the local rebuild in :func:`run_sync`, so this device's own
    records already reflect the merged log; the merge then unions in whatever
    another device knows and max-count wins per food (see
    :func:`diet_guard._sync_merge.food_bank_to_log`).

    Strictly speaking the bank is derivable from the already-synced log, so
    both devices converge on their own eventually.  Syncing it makes them
    agree *now*, and publishes the bank so a fresh device has autocomplete
    before it has replayed anything.

    **The log stays authoritative for which foods exist.**  A CRDT union
    never shrinks, so without this the max-count merge would resurrect a food
    whose entries were all undone -- a peer's stale copy would out-clock the
    local absence and be written back and re-pushed forever, un-deletable.
    Restricting the result to the foods the freshly-rebuilt local bank still
    contains fixes that, and stays identical across devices because that
    rebuild comes from the *merged* log both devices share.
    """
    identity = device_identity()
    local = read_food_bank()
    merged = food_bank_to_log(local)
    for device_id in client.list_directory(_DEVICES_DIR):
        if identity.is_own(device_id):
            continue
        text = client.get_file_text(_device_food_bank_path(device_id))
        if text is None:
            continue
        try:
            merged = merge_logs(merged, parse_remote_food_bank(text))
        except (TypeError, KeyError, ValueError, json.JSONDecodeError):
            _logger.warning(
                "Unparsable food bank pushed by device %r, skipping",
                device_id,
            )

    if not merged:
        return
    resolved = {
        name: record
        for name, record in log_to_food_bank(merged).items()
        if name in local
    }
    write_food_bank(resolved)
    merged = food_bank_to_log(resolved)
    client.put_file_text(
        _device_food_bank_path(identity.device_id),
        json.dumps(
            {record_id: record.to_dict() for record_id, record in merged.items()},
            indent=2,
        ),
        message="diet_guard sync",
    )


def _sync_manual_bank(client: GitHubSyncClient) -> None:
    """Pull, merge, persist and push the hand-curated food bank.

    Curated entries are the one part of the bank that is not derivable from
    the food log (see :mod:`diet_guard._foodbank_manual`), so unlike
    ``food_bank.json`` they need a real merge: last-writer-wins per food name
    by edit time, union across devices.
    """
    identity = device_identity()
    merged = manual_bank_to_log(read_manual_bank())
    for device_id in client.list_directory(_DEVICES_DIR):
        if identity.is_own(device_id):
            continue
        text = client.get_file_text(_device_manual_bank_path(device_id))
        if text is None:
            continue
        try:
            merged = merge_logs(merged, parse_remote_manual_bank(text))
        except (TypeError, KeyError, ValueError, json.JSONDecodeError):
            _logger.warning(
                "Unparsable curated food bank pushed by device %r, skipping",
                device_id,
            )

    if not merged:
        # No device has curated anything: nothing to persist, and pushing an
        # empty object every tick would be pure churn.
        return
    write_manual_bank(log_to_manual_bank(merged))
    client.put_file_text(
        _device_manual_bank_path(identity.device_id),
        json.dumps(
            {record_id: record.to_dict() for record_id, record in merged.items()},
            indent=2,
        ),
        message="diet_guard sync",
    )


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
    identity = device_identity()
    merged = budget_to_log(read_raw_record(), load_entries())
    for device_id in client.list_directory(_DEVICES_DIR):
        if identity.is_own(device_id):
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
    merged_history = log_to_history(merged)
    # Only write back when the merge actually carried history. A pre-feature
    # peer contributes none, and persisting an empty document would look like
    # "history already exists" to any presence-based check and stop the local
    # seed from ever running.
    if merged_history:
        write_raw_history(history_to_json(merged_history))

    push_json = json.dumps(
        {record_id: record.to_dict() for record_id, record in merged.items()},
        indent=2,
    )
    client.put_file_text(
        _device_budget_path(identity.device_id),
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
    client = _remote_client(
        GitHubSyncClient(
            SYNC_REPO_OWNER,
            SYNC_REPO_NAME,
            token,
            timeout_seconds=SYNC_TIMEOUT_SECONDS,
        )
    )

    identity = device_identity()
    state_store = FileSyncStateStore(SYNC_STATE_FILE)
    state = state_store.load()
    remote_revs = _remote_revisions(client)
    seen_revs: dict[str, str] = {}

    merged = daylog_to_log(read_raw_log())
    for remote_log in _pull_remote_logs(
        client, remote_revs, state, seen_revs, identity
    ):
        merged = merge_logs(merged, remote_log)

    merged_daylog = log_to_daylog(merged)
    resigned: DayLog = {
        day: [resign_entry(entry) for entry in entries]
        for day, entries in merged_daylog.items()
    }
    write_raw_log(resigned)
    rebuild_food_bank(resigned)
    _sync_budget(client)
    _sync_food_bank(client)
    _sync_manual_bank(client)

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
