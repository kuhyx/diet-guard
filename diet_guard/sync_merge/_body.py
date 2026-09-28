"""Body document <-> ``crdt_sync.Log`` adapters (profile, weights, workouts).

Wire format in ``docs/DOCS-body.md``: record ``profile`` with one field per
profile value; one record per day for each of weights (``w:<YYYY-MM-DD>``),
body fat (``bf:...``) and phone-written steps (``st:...``); and one
``activity`` record carrying the PC's published sessions. Every field's Hlc
is derived from its own ``t`` edit stamp, so an unchanged document
re-derives identical clocks and re-syncing it is a no-op -- the same
determinism the budget adapter relies on.

KEEP IN SYNC WITH ``app/lib/services/sync_merge_body.dart``.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
import json
from typing import TYPE_CHECKING

from crdt_sync import Hlc, Record

from diet_guard._device import device_id
from diet_guard.sync_merge._clock import _wall_time_ms

if TYPE_CHECKING:
    from crdt_sync import Log

PROFILE_RECORD_ID = "profile"
ACTIVITY_RECORD_ID = "activity"


@dataclass(frozen=True)
class DatedLog:
    """One per-day section: its record prefix, field name and value keys."""

    section: str
    prefix: str
    field: str
    keys: tuple[str, ...]


# Weights, body fat and (phone-written) steps all sync the same way: one
# record per date, one field holding a small map, LWW by its edit stamp.
DATED_LOGS: tuple[DatedLog, ...] = (
    DatedLog("weights", "w:", "kg", ("kg", "src")),
    DatedLog("bodyfat", "bf:", "pct", ("pct",)),
    DatedLog("steps", "st:", "n", ("n",)),
)
_DEFAULTS: dict[str, object] = {"src": ""}


def _hlc(stamp: object) -> Hlc:
    """The deterministic clock for an edit stamp (epoch when unparsable)."""
    return Hlc.new_tick(device_id(), wall_time_ms=_wall_time_ms(str(stamp)))


def _stamp(hlc: Hlc) -> str:
    """The local ISO edit stamp a merged field's clock stands for."""
    moment = datetime.fromtimestamp(hlc.wall_time_ms / 1000, tz=UTC)
    return moment.astimezone().isoformat(timespec="seconds")


def body_to_log(doc: dict[str, dict[str, object]]) -> Log:
    """Convert the local Body document (see ``_body_store``) into a Log."""
    log: Log = {}
    profile_fields = {
        name: (cell.get("v"), _hlc(cell.get("t")))
        for name, cell in doc["profile"].items()
        if isinstance(cell, dict)
    }
    if profile_fields:
        log[PROFILE_RECORD_ID] = Record(id=PROFILE_RECORD_ID, fields=profile_fields)
    for dated in DATED_LOGS:
        for day, cell in doc[dated.section].items():
            if not isinstance(cell, dict):
                continue
            record_id = f"{dated.prefix}{day}"
            value = {key: cell.get(key, _DEFAULTS.get(key)) for key in dated.keys}
            hlc = _hlc(cell.get("t"))
            log[record_id] = Record(id=record_id, fields={dated.field: (value, hlc)})
    sessions = doc["activity"].get("sessions")
    if isinstance(sessions, list):
        hlc = _hlc(doc["activity"].get("t"))
        log[ACTIVITY_RECORD_ID] = Record(
            id=ACTIVITY_RECORD_ID, fields={"sessions": (sessions, hlc)}
        )
    return log


def _dated_cell(dated: DatedLog, record: Record) -> dict[str, object] | None:
    """One dated record back as a local cell, or None when malformed."""
    if dated.field not in record.fields:
        return None
    value, hlc = record.fields[dated.field]
    if not isinstance(value, dict):
        return None
    cell = {key: value.get(key, _DEFAULTS.get(key)) for key in dated.keys}
    return {**cell, "t": _stamp(hlc)}


def log_to_body(log: Log) -> dict[str, dict[str, object]]:
    """Convert a merged Log back into the local document shape."""
    doc: dict[str, dict[str, object]] = {
        "profile": {},
        "activity": {},
        **{dated.section: {} for dated in DATED_LOGS},
    }
    profile = log.get(PROFILE_RECORD_ID)
    if profile is not None:
        doc["profile"] = {
            name: {"v": value, "t": _stamp(hlc)}
            for name, (value, hlc) in profile.fields.items()
        }
    for record_id, record in log.items():
        for dated in DATED_LOGS:
            if record_id.startswith(dated.prefix):
                cell = _dated_cell(dated, record)
                if cell is not None:
                    doc[dated.section][record_id[len(dated.prefix) :]] = cell
    activity = log.get(ACTIVITY_RECORD_ID)
    if activity is not None and "sessions" in activity.fields:
        sessions, hlc = activity.fields["sessions"]
        if isinstance(sessions, list):
            doc["activity"] = {"sessions": sessions, "t": _stamp(hlc)}
    return doc


def parse_remote_body(text: str) -> Log:
    """Parse one device's pushed ``body.json`` into a Log.

    Raises:
        TypeError: The top level is not a JSON object.
        KeyError: Via ``Record.from_dict`` on a record missing a key.
        ValueError: Invalid JSON, or a malformed clock string.
    """
    raw = json.loads(text)
    if not isinstance(raw, dict):
        msg = f"top-level body payload is not a JSON object: {raw!r}"
        raise TypeError(msg)
    return {record_id: Record.from_dict(data) for record_id, data in raw.items()}


def encode_body_for_push(log: Log) -> str:
    """Serialise a merged Log for push."""
    return json.dumps(
        {record_id: record.to_dict() for record_id, record in log.items()},
        indent=2,
        sort_keys=True,
    )
