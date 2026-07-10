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
"""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from typing import TYPE_CHECKING

from crdt_sync import Hlc, Record

from diet_guard._constants import SYNC_DEVICE_ID

if TYPE_CHECKING:
    from crdt_sync import Log

    from diet_guard._state import DayLog

_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


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
