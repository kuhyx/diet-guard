"""Pull/merge/push for the food bank and the budget.

Split out of ``_sync.py`` for file size. These three run inside the same tick
as the food-log sync but are independent of it: each owns one remote document,
merges it with ``crdt_sync``'s LWW, writes the merged result back locally and
pushes it.

The derived bank merges by ``count`` (max-count-wins, idempotent -- the right
merge for a counter derived from the log), the curated bank by ``editedAt``,
and the budget by its ``t`` edit stamp. All three are per-field LWW over the
*union* of field names, so a device predating a field relays it untouched.
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING

from crdt_sync import merge_logs

from diet_guard._budget import read_raw_record, write_raw_record
from diet_guard._budget_history import (
    history_to_json,
    load_entries,
    write_raw_history,
)
from diet_guard._device import device_identity
from diet_guard._foodbank import read_food_bank, write_food_bank
from diet_guard._foodbank_manual import read_manual_bank, write_manual_bank
from diet_guard._meal_schedule_store import (
    history_to_json as schedule_history_to_json,
)
from diet_guard._meal_schedule_store import (
    load_entries as load_schedule_entries,
)
from diet_guard._meal_schedule_store import (
    write_raw_history as write_raw_schedule,
)
from diet_guard._sync_paths import (
    _DEVICES_DIR,
    _device_budget_path,
    _device_food_bank_path,
    _device_manual_bank_path,
)
from diet_guard.sync_merge import (
    budget_to_log,
    food_bank_to_log,
    log_to_budget,
    log_to_food_bank,
    log_to_history,
    log_to_manual_bank,
    log_to_schedule_history,
    manual_bank_to_log,
    parse_remote_budget,
    parse_remote_food_bank,
    parse_remote_manual_bank,
)

if TYPE_CHECKING:
    from crdt_sync import GitHubSyncClient

_logger = logging.getLogger(__name__)


def _sync_food_bank(client: GitHubSyncClient) -> None:
    """Pull, merge, persist and push the log-derived food bank.

    Runs *after* the local rebuild in :func:`run_sync`, so this device's own
    records already reflect the merged log; the merge then unions in whatever
    another device knows and max-count wins per food (see
    :func:`diet_guard.sync_merge.food_bank_to_log`).

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
    :mod:`diet_guard.sync_merge`'s budget adapters), not the food log's
    union-of-immutable-entries -- a budget can be edited repeatedly. A
    device that has never run ``init`` neither contributes a local record
    to the merge nor overwrites a real budget pulled from elsewhere, and if
    *no* device has ever set one, nothing is written or pushed.
    """
    identity = device_identity()
    merged = budget_to_log(read_raw_record(), load_entries(), load_schedule_entries())
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
    # Same guard for the meal schedule: a pre-feature peer contributes no
    # `sched:` fields, and writing the empty document back would discard this
    # device's own history.
    merged_schedule = log_to_schedule_history(merged)
    if merged_schedule:
        write_raw_schedule(schedule_history_to_json(merged_schedule))

    push_json = json.dumps(
        {record_id: record.to_dict() for record_id, record in merged.items()},
        indent=2,
    )
    client.put_file_text(
        _device_budget_path(identity.device_id),
        push_json,
        message="diet_guard sync",
    )
