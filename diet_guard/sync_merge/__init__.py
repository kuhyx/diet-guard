"""Entry <-> ``crdt_sync.Record`` adapters for diet_guard's cross-device sync.

diet_guard's own on-disk ``food_log.json`` format is unchanged (a
:class:`~diet_guard._state.DayLog`: date string -> list of entry dicts) --
only the GitHub-synced wire format and the cross-device merge algorithm go
through ``crdt_sync``'s ``Record``/``Log``/``Hlc`` primitives, the same ones
every other kuhy app that syncs this way uses (see ``~/crdt-sync``).

Split into three submodules for file size, along the same seams the tests
already use:

* :mod:`._daylog` -- the food log itself, including the legacy-format fallback
* :mod:`._budget` -- the budget record and its ``hist:`` history fields
* :mod:`._banks` -- the derived and curated halves of the food bank
* :mod:`._kuchnia` -- the catering panel credential

Everything public is re-exported here, so ``from diet_guard.sync_merge import
parse_remote_log`` reaches the same object the flat module exposed. (The
``merge_logs`` these adapters feed is ``crdt_sync``'s, imported directly by
:mod:`diet_guard._sync` -- it was never defined here.)
"""

from __future__ import annotations

from diet_guard.sync_merge._banks import (
    food_bank_to_log,
    log_to_food_bank,
    log_to_manual_bank,
    manual_bank_to_log,
    parse_remote_food_bank,
    parse_remote_manual_bank,
)
from diet_guard.sync_merge._budget import (
    _budget_hlc,
    budget_to_log,
    log_to_budget,
    log_to_history,
    parse_remote_budget,
)
from diet_guard.sync_merge._daylog import (
    _entry_hlc,
    _legacy_entry_id,
    daylog_to_log,
    entry_to_record,
    log_to_daylog,
    parse_remote_log,
    record_to_entry,
)
from diet_guard.sync_merge._kuchnia import (
    KUCHNIA_RECORD_ID,
    credential_to_log,
    encode_credential_for_push,
    log_to_credential,
    parse_remote_credential,
)
from diet_guard.sync_merge._schedule import (
    SCHEDULE_FIELD_PREFIX,
    log_to_schedule_history,
    schedule_fields,
)

__all__ = [
    "KUCHNIA_RECORD_ID",
    # Private helpers the tests reach for directly. Re-exported deliberately:
    # they were importable from the flat module, and dropping them here would
    # break those tests for a naming reason rather than a behavioural one.
    "SCHEDULE_FIELD_PREFIX",
    "_budget_hlc",
    "_entry_hlc",
    "_legacy_entry_id",
    "budget_to_log",
    "credential_to_log",
    "daylog_to_log",
    "encode_credential_for_push",
    "entry_to_record",
    "food_bank_to_log",
    "log_to_budget",
    "log_to_credential",
    "log_to_daylog",
    "log_to_food_bank",
    "log_to_history",
    "log_to_manual_bank",
    "log_to_schedule_history",
    "manual_bank_to_log",
    "parse_remote_budget",
    "parse_remote_credential",
    "parse_remote_food_bank",
    "parse_remote_log",
    "parse_remote_manual_bank",
    "record_to_entry",
    "schedule_fields",
]
