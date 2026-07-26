"""Entry <-> crdt_sync.Record adapters for diet_guard's cross-device sync.

diet_guard's own on-disk ``food_log.json`` format is unchanged (a
:class:`~diet_guard._state.DayLog`: date string -> list of entry dicts) --
only the GitHub-synced wire format and the cross-device merge algorithm now
go through ``crdt_sync``'s ``Record``/``Log``/``Hlc`` primitives, the same
ones every other kuhy app that syncs this way uses (see ``~/crdt-sync``).

Each diet_guard entry maps to one ``Record`` with a single opaque ``body``
field holding everything except ``id``/``deleted``: entries are immutable
after creation (only ``deleted`` ever changes post-write, see
:func:`diet_guard._state.resign_entry`), so there is no benefit to
``crdt_sync``'s per-field LWW granularity here -- the whole body shares one
derived ``Hlc``. ``hmac`` travels inside ``body`` like any other field but
is never trusted on read; :func:`diet_guard._sync.run_sync` always re-signs
after merging, exactly as before this migration.

Backward compatible with devices not yet migrated (the phone app, for now):
:func:`parse_remote_log` tries the new Record-based wire format first and
falls back to the old plain-DayLog format, converting old-format entries
through the same adapters used for the local log. Push always writes the
new format -- there is no code path left that ever *writes* the old one.

The budget adapters at the bottom of this module (:func:`budget_to_log`
etc.) follow the same ``Record``/``Log`` shape, but differ in one important
way: a budget record is edited repeatedly (not immutable-after-creation
like a food-log entry), so its ``Hlc`` is derived from a ``t`` edit
timestamp that :func:`diet_guard._budget.write_budget` bumps on every
write, rather than from a birth time that never changes. There is no
legacy plain-``DayLog``-shaped fallback for budgets -- ``budget.json`` is a
brand-new sync payload, so every device pushing it already speaks the
Record-based wire format.
"""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from typing import TYPE_CHECKING

from crdt_sync import Hlc, Record

from diet_guard._budget_history import BudgetEntry
from diet_guard._constants import SYNC_DEVICE_ID
from diet_guard._foodbank_manual import record_edit_time

if TYPE_CHECKING:
    from collections.abc import Mapping

    from crdt_sync import Log

    from diet_guard._state import DayLog

_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def _wall_time_ms(stamp: str) -> int:
    """Return ``stamp``'s epoch milliseconds, or the epoch when unparsable."""
    try:
        moment = datetime.fromisoformat(stamp)
    except ValueError:
        moment = _EPOCH
    return int(moment.timestamp() * 1000)


def _entry_hlc(entry: dict[str, object]) -> Hlc:
    """Derive a deterministic Hlc for ``entry`` from its own ``time`` field.

    The same entry always yields the same Hlc regardless of when this runs
    -- entries are immutable after creation, so there's no real "now" to
    stamp, just the birth-time already recorded on the entry itself.
    Malformed/missing ``time`` still gets a valid (if early-sorting) Hlc
    rather than raising -- this only affects tie-breaking between
    otherwise-identical copies of the same id, never whether the entry
    survives a merge.
    """
    try:
        dt = datetime.fromisoformat(str(entry.get("time", "")))
    except ValueError:
        dt = _EPOCH
    wall_time_ms = int(dt.timestamp() * 1000)
    return Hlc.new_tick(SYNC_DEVICE_ID, wall_time_ms=wall_time_ms)


def _legacy_entry_id(entry: dict[str, object]) -> str:
    """Deterministic id for a pre-``id`` legacy entry, from ``(time, desc)``.

    Two devices holding the same legacy entry independently derive the same
    id without communicating, so they merge as one record instead of two --
    the same guarantee the old ``(time, desc)`` dedup key gave, just
    expressed as a real id going forward.
    """
    key = f"{entry.get('time')}|{entry.get('desc')}"
    digest = hashlib.sha256(key.encode()).hexdigest()[:32]
    return f"legacy-{digest}"


def entry_to_record(entry: dict[str, object]) -> Record:
    """Convert one diet_guard log entry to a ``crdt_sync.Record``."""
    entry_id = entry.get("id")
    if not isinstance(entry_id, str) or not entry_id:
        entry_id = _legacy_entry_id(entry)
    hlc = _entry_hlc(entry)
    body = {k: v for k, v in entry.items() if k not in ("id", "deleted")}
    deleted = bool(entry.get("deleted", False))
    return Record(
        id=entry_id,
        fields={"body": (body, hlc)},
        deleted=deleted,
        deleted_hlc=hlc if deleted else None,
    )


def record_to_entry(record: Record) -> dict[str, object]:
    """Convert one ``crdt_sync.Record`` back to a diet_guard log entry."""
    body_value, _hlc = record.fields.get("body", ({}, None))
    entry: dict[str, object] = dict(body_value) if isinstance(body_value, dict) else {}
    entry["id"] = record.id
    if record.deleted:
        entry["deleted"] = True
    return entry


def daylog_to_log(daylog: DayLog) -> Log:
    """Convert a full local/remote DayLog into a ``crdt_sync.Log``."""
    log: Log = {}
    for entries in daylog.values():
        for entry in entries:
            record = entry_to_record(entry)
            log[record.id] = record
    return log


def log_to_daylog(log: Log) -> DayLog:
    """Convert a merged ``crdt_sync.Log`` back into DayLog shape.

    Each entry is re-bucketed under its own ``time``'s date rather than
    whatever date key it might have arrived under, and each day's entries
    are sorted oldest-first -- matching the existing on-disk convention.
    """
    daylog: DayLog = {}
    for record in log.values():
        entry = record_to_entry(record)
        date_key = str(entry.get("time", ""))[:10]
        daylog.setdefault(date_key, []).append(entry)
    for entries in daylog.values():
        entries.sort(key=lambda entry: str(entry.get("time", "")))
    return daylog


def _looks_like_new_format(raw: dict[str, object]) -> bool:
    """Return True if ``raw`` is shaped like a crdt_sync Record-keyed Log.

    An empty object is ambiguous but harmless either way (no entries to
    convert), so it's treated as new format to skip the old-format
    conversion pass for nothing.
    """
    return all(
        isinstance(value, dict) and "fields" in value and "id" in value
        for value in raw.values()
    )


def parse_remote_log(text: str) -> Log:
    """Parse one device's pushed log text into a ``crdt_sync.Log``.

    Tries the new Record-based wire format first; falls back to the old
    plain-DayLog format (today's on-the-wire shape) for devices not yet
    migrated onto crdt_sync, converting their entries through the same
    adapter the local log uses. Raises on genuinely malformed data, same as
    the pre-migration behavior -- the caller
    (:func:`diet_guard._sync._pull_remote_logs`) already logs-and-skips on
    that.

    Raises:
        TypeError: If the top-level JSON isn't an object, or a "new format"
            value or an old-format day's entries aren't shaped as expected.
        KeyError: Via ``Record.from_dict``, if a "new format" record is
            missing an expected key.
        ValueError: Via ``json.loads`` on invalid JSON, or ``Hlc.from_str``
            on a malformed clock string.
    """
    raw = json.loads(text)
    if not isinstance(raw, dict):
        msg = f"top-level sync payload is not a JSON object: {raw!r}"
        raise TypeError(msg)
    if _looks_like_new_format(raw):
        return {record_id: Record.from_dict(data) for record_id, data in raw.items()}

    daylog: DayLog = {}
    for date_key, entries in raw.items():
        if not isinstance(entries, list):
            msg = f"day {date_key!r} is not a JSON array: {entries!r}"
            raise TypeError(msg)
        for entry in entries:
            if not isinstance(entry, dict):
                msg = f"entry under day {date_key!r} is not a JSON object: {entry!r}"
                raise TypeError(msg)
        daylog[date_key] = entries
    return daylog_to_log(daylog)


# Stable id: exactly one budget record per device-pushed budget.json.
_BUDGET_RECORD_ID = "budget"
# Field-name prefix for the effective-from budget history, one field per date.
# A separate *field* rather than a separate document, because merge_record
# unions field names -- see budget_to_log.
_HISTORY_FIELD_PREFIX = "hist:"
# Body weight, as its own field rather than a key inside ``value``.  It is
# shared state like everything else -- both devices must see one value -- but
# it needs its own Hlc so a device that never sets it (the phone) cannot
# delete it merely by pushing a budget edit.
_WEIGHT_FIELD = "weight"


def _budget_hlc(record: dict[str, object]) -> Hlc:
    """Derive a deterministic Hlc for a raw budget record from its ``t`` field.

    Mirrors :func:`_entry_hlc`'s determinism -- the same unedited record
    always yields the same Hlc, so re-syncing an unchanged budget is a
    no-op -- but reads ``t`` (bumped on every :func:`diet_guard._budget.
    write_budget` call) rather than a fixed birth time, since a budget can
    be edited repeatedly and the *edit* time is what last-writer-wins must
    compare.
    """
    try:
        dt = datetime.fromisoformat(str(record.get("t", "")))
    except ValueError:
        dt = _EPOCH
    wall_time_ms = int(dt.timestamp() * 1000)
    return Hlc.new_tick(SYNC_DEVICE_ID, wall_time_ms=wall_time_ms)


def _history_hlc(entry: BudgetEntry) -> Hlc:
    """Derive a deterministic Hlc for one history entry from its edit time.

    Same trick as :func:`_budget_hlc`: identical inputs always yield the same
    clock, so re-syncing unchanged history is a no-op.  Two devices that seed
    the history independently derive the same ``wall_time_ms`` and the same
    value and differ only in node id, so whichever side wins the field-level
    LWW, the value is identical and the merge converges in one round.
    """
    try:
        moment = datetime.fromisoformat(entry.edited_at)
    except ValueError:
        moment = _EPOCH
    return Hlc.new_tick(SYNC_DEVICE_ID, wall_time_ms=int(moment.timestamp() * 1000))


def budget_to_log(
    record: dict[str, object] | None,
    entries: tuple[BudgetEntry, ...] = (),
) -> Log:
    """Convert a raw local budget record plus its history into a Log.

    Returns an empty ``Log`` when ``record`` is None (this device has never
    run ``init``), so an uninitialized device contributes nothing to the
    merge rather than clobbering another device's real value.

    The history rides along as one ``hist:<YYYY-MM-DD>`` field per entry on
    the *same* record.  ``crdt_sync``'s ``merge_record`` is per-field LWW over
    the union of field names, so a device that predates the history neither
    clobbers those fields nor blocks them: it merges them in from the remote
    and pushes them straight back out (both sides push the *merged* log).
    That is what makes this safe to roll out without a coordinated release.

    ``w`` (body weight) travels the same way, as its own :data:`_WEIGHT_FIELD`
    rather than as a key inside ``value``.  It is shared state -- both devices
    must agree on it -- but inside ``value`` it was collateral damage of the
    whole-map LWW: the phone rebuilds that map without ``w``, so any phone
    budget edit silently deleted the stored weight and with it the protein
    target.  As its own field it is protected by per-field LWW, and a device
    that never sets it relays it untouched instead of dropping it.
    """
    if record is None:
        return {}
    hlc = _budget_hlc(record)
    value = {k: v for k, v in record.items() if k not in {"t", "w"}}
    fields: dict[str, tuple[object, Hlc]] = {"value": (value, hlc)}
    weight = record.get("w")
    if isinstance(weight, (int, float)) and not isinstance(weight, bool):
        fields[_WEIGHT_FIELD] = (float(weight), hlc)
    for entry in entries:
        fields[f"{_HISTORY_FIELD_PREFIX}{entry.effective_from}"] = (
            entry.kcal,
            _history_hlc(entry),
        )
    rec = Record(id=_BUDGET_RECORD_ID, fields=fields)
    return {rec.id: rec}


def log_to_history(log: Log) -> tuple[BudgetEntry, ...]:
    """Extract the effective-from history from a merged budget ``Log``.

    Each entry's ``edited_at`` is reconstructed from its field Hlc rather than
    carried separately, so the stored timestamp and the clock the merge
    compared can never drift apart.
    """
    record = log.get(_BUDGET_RECORD_ID)
    if record is None:
        return ()
    entries = []
    for name, (value, hlc) in record.fields.items():
        if not name.startswith(_HISTORY_FIELD_PREFIX):
            continue
        if isinstance(value, bool) or not isinstance(value, int):
            continue
        edited = datetime.fromtimestamp(hlc.wall_time_ms / 1000, tz=timezone.utc)
        entries.append(
            BudgetEntry(
                effective_from=name[len(_HISTORY_FIELD_PREFIX) :],
                kcal=value,
                edited_at=edited.astimezone().isoformat(timespec="seconds"),
            ),
        )
    return tuple(sorted(entries, key=lambda e: e.effective_from))


def log_to_budget(log: Log) -> dict[str, object] | None:
    """Convert a merged budget ``Log`` back into a raw budget record.

    Returns None when the log has no budget record at all (neither device
    has ever run ``init`` yet) -- callers treat that as "nothing to write
    locally", not an error.
    """
    record = log.get(_BUDGET_RECORD_ID)
    if record is None:
        return None
    value, hlc = record.fields.get("value", ({}, None))
    result: dict[str, object] = dict(value) if isinstance(value, dict) else {}
    if hlc is not None:
        winning_time = datetime.fromtimestamp(hlc.wall_time_ms / 1000, tz=timezone.utc)
        result["t"] = winning_time.astimezone().isoformat(timespec="seconds")
    weight, _ = record.fields.get(_WEIGHT_FIELD, (None, None))
    if isinstance(weight, (int, float)) and not isinstance(weight, bool):
        result["w"] = float(weight)
    return result


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
        hlc = Hlc.new_tick(SYNC_DEVICE_ID, wall_time_ms=ticks)
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
            SYNC_DEVICE_ID,
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


def parse_remote_budget(text: str) -> Log:
    """Parse one device's pushed ``budget.json`` text into a ``crdt_sync.Log``.

    Raises on malformed data; the caller
    (:func:`diet_guard._sync._pull_remote_budgets`) logs-and-skips on that,
    matching :func:`parse_remote_log`'s tolerance for a bad device file.

    Raises:
        TypeError: If the top-level JSON isn't an object, or a record value
            isn't shaped as expected.
        KeyError: Via ``Record.from_dict``, if a record is missing an
            expected key.
        ValueError: Via ``json.loads`` on invalid JSON, or ``Hlc.from_str``
            on a malformed clock string.
    """
    raw = json.loads(text)
    if not isinstance(raw, dict):
        msg = f"top-level budget payload is not a JSON object: {raw!r}"
        raise TypeError(msg)
    return {record_id: Record.from_dict(data) for record_id, data in raw.items()}
