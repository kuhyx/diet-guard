"""Food-bank <-> ``crdt_sync.Record`` adapters, for both halves of the bank.

The derived bank's merge clock is the record's own ``count``, not a wall time:
last-writer-wins therefore means *max-count-wins*, which is the correct merge
for a derived counter (the device that has seen more of the log has the higher
count) and is idempotent, since the count only moves when the log does.

The curated bank is one record per normalized name, LWW by an ``editedAt``
stamp -- those foods were never eaten, so they are not derivable from any log.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
from typing import TYPE_CHECKING

from crdt_sync import Hlc, Record

from diet_guard._device import device_id
from diet_guard._foodbank_manual import record_edit_time
from diet_guard.sync_merge._clock import _wall_time_ms

if TYPE_CHECKING:
    from collections.abc import Mapping

    from crdt_sync import Log


def food_bank_to_log(bank: Mapping[str, object]) -> Log:
    """Convert the log-derived food bank into a ``crdt_sync.Log``.

    The bank is *derived* -- both devices replay the same synced log and
    compute the same records -- so this exists to make them agree
    **immediately** rather than only after each has replayed, and to let a
    device that is missing part of the log still autocomplete the other's
    foods.

    The clock is the record's own ``count``, not a wall time.  That makes
    last-writer-wins mean *max-count-wins*, which is the right merge for a
    derived counter: a device that has seen more of the log has the higher
    count, and re-merging is idempotent because the count does not move
    unless the log did.  It also avoids inventing an edit timestamp for a
    record nobody edits.
    """
    log: Log = {}
    for name, record in bank.items():
        if not isinstance(record, dict):
            continue
        count = record.get("count")
        ticks = int(count) if isinstance(count, (int, float)) else 0
        hlc = Hlc.new_tick(device_id(), wall_time_ms=ticks)
        log[name] = Record(id=name, fields={"body": (dict(record), hlc)})
    return log


def log_to_food_bank(log: Log) -> dict[str, dict[str, object]]:
    """Convert a merged food-bank ``Log`` back into on-disk bank shape."""
    bank: dict[str, dict[str, object]] = {}
    for name, record in log.items():
        if record.deleted:
            continue
        body, _hlc = record.fields.get("body", ({}, None))
        if isinstance(body, dict):
            bank[name] = dict(body)
    return bank


def parse_remote_food_bank(text: str) -> Log:
    """Parse one device's pushed ``food_bank.json`` into a ``crdt_sync.Log``.

    Raises:
        TypeError: If the top-level JSON isn't an object.
        KeyError: Via ``Record.from_dict``, on a record missing a key.
        ValueError: Via ``json.loads``/``Hlc.from_str`` on malformed input.
    """
    raw = json.loads(text)
    if not isinstance(raw, dict):
        msg = f"top-level food-bank payload is not a JSON object: {raw!r}"
        raise TypeError(msg)
    return {record_id: Record.from_dict(data) for record_id, data in raw.items()}


def manual_bank_to_log(bank: Mapping[str, object]) -> Log:
    """Convert the hand-curated food bank into a ``crdt_sync.Log``.

    One record per normalized food name, carrying the whole bank record as an
    opaque ``body`` -- the same shape food-log entries use.  Unlike an entry
    a curated food is editable, so its Hlc comes from the record's own ``t``
    edit stamp (like the budget's) rather than a fixed birth time.
    """
    log: Log = {}
    for name, record in bank.items():
        if not isinstance(record, dict):
            continue
        hlc = Hlc.new_tick(
            device_id(),
            wall_time_ms=_wall_time_ms(record_edit_time(record)),
        )
        body = {k: v for k, v in record.items() if k != "t"}
        log[name] = Record(id=name, fields={"body": (body, hlc)})
    return log


def log_to_manual_bank(log: Log) -> dict[str, dict[str, object]]:
    """Convert a merged curated-bank ``Log`` back into on-disk bank shape."""
    bank: dict[str, dict[str, object]] = {}
    for name, record in log.items():
        if record.deleted:
            continue
        body, hlc = record.fields.get("body", ({}, None))
        if not isinstance(body, dict):
            continue
        stored = dict(body)
        if hlc is not None:
            winning = datetime.fromtimestamp(hlc.wall_time_ms / 1000, tz=timezone.utc)
            stored["t"] = winning.astimezone().isoformat(timespec="seconds")
        bank[name] = stored
    return bank


def parse_remote_manual_bank(text: str) -> Log:
    """Parse one device's pushed curated-bank text into a ``crdt_sync.Log``.

    Raises on malformed data; the caller logs-and-skips, matching every other
    remote parser here.

    Raises:
        TypeError: If the top-level JSON isn't an object.
        KeyError: Via ``Record.from_dict``, on a record missing a key.
        ValueError: Via ``json.loads``/``Hlc.from_str`` on malformed input.
    """
    raw = json.loads(text)
    if not isinstance(raw, dict):
        msg = f"top-level curated-bank payload is not a JSON object: {raw!r}"
        raise TypeError(msg)
    return {record_id: Record.from_dict(data) for record_id, data in raw.items()}
