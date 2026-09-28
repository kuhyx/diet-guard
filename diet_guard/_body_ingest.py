"""Phone weigh-ins (wake-alarm's morning session) -> the Body weight log.

The wake-alarm phone app publishes ``latest_weight_kg`` and a short
``morning_sessions`` list on its own ``alarm.json`` in the shared Firebase
project. Reading it through diet_guard's *own* sync client -- paths are
absolute there -- means no import of ``wake_alarm`` and no second sign-in.

Stamping rules (``docs/DOCS-body.md``): ``latest_weight_kg`` carries its
field's Hlc time, so a re-typed weigh-in wins; ``morning_sessions`` entries
are stamped midnight UTC of their date and only fill gaps, because that list
is republished every morning with a fresh Hlc and would otherwise overwrite
manual corrections daily.

KEEP IN SYNC WITH ``app/lib/services/wake_alarm_weights.dart``.
"""

from __future__ import annotations

from datetime import UTC, datetime
import json
import logging
from typing import TYPE_CHECKING

from crdt_sync import Hlc, MirrorSyncClient, RemoteSyncError

from diet_guard._body_store import MAX_KG, MIN_KG, WeightCandidate, stamp_ms

if TYPE_CHECKING:
    from crdt_sync import RemoteStore

_logger = logging.getLogger(__name__)

WAKE_ALARM_DEVICES_DIR = "wake-alarm-sync/devices"
_LATEST_FIELD = "latest_weight_kg"
_SESSIONS_FIELD = "morning_sessions"
# A crdt_sync field on the wire is ``[value, hlc]``.
_PAIR_LEN = 2


def _pair(log: object, field: str) -> tuple[object, str]:
    """``(value, hlc)`` of one field on the ``alarm`` record, or ``(None, "")``."""
    record = log.get("alarm") if isinstance(log, dict) else None
    fields = record.get("fields") if isinstance(record, dict) else None
    pair = fields.get(field) if isinstance(fields, dict) else None
    if not isinstance(pair, list) or len(pair) < _PAIR_LEN:
        return None, ""
    return pair[0], str(pair[1])


def _kg(value: object) -> float | None:
    """A sane body weight, or None."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    kg = float(value)
    return kg if MIN_KG <= kg <= MAX_KG else None


def _hlc_stamp(hlc: str) -> str | None:
    """The ISO instant an Hlc string was minted at, or None if unparsable."""
    try:
        wall = Hlc.from_str(hlc).wall_time_ms
    except ValueError:
        return None
    return datetime.fromtimestamp(wall / 1000, tz=UTC).isoformat(timespec="seconds")


def _from_log(log: object) -> list[WeightCandidate]:
    """Every weigh-in one device's alarm log offers."""
    found: list[WeightCandidate] = []
    sessions, _ = _pair(log, _SESSIONS_FIELD)
    for entry in sessions if isinstance(sessions, list) else []:
        day = entry.get("date") if isinstance(entry, dict) else None
        kg = _kg(entry.get("weight_kg")) if isinstance(entry, dict) else None
        if isinstance(day, str) and kg is not None:
            found.append(WeightCandidate(day, kg, "phone", f"{day}T00:00:00+00:00"))
    latest, hlc = _pair(log, _LATEST_FIELD)
    day = latest.get("date") if isinstance(latest, dict) else None
    kg = _kg(latest.get("kg")) if isinstance(latest, dict) else None
    stamp = _hlc_stamp(hlc)
    if isinstance(day, str) and kg is not None and stamp is not None:
        found.append(WeightCandidate(day, kg, "phone", stamp))
    return found


def weight_candidates(published: list[tuple[str, str]]) -> list[WeightCandidate]:
    """One candidate per date -- the newest-stamped -- across every device.

    Args:
        published: ``(device_id, raw alarm.json)`` per wake-alarm device.
    """
    best: dict[str, WeightCandidate] = {}
    for _, raw in published:
        try:
            log = json.loads(raw)
        except json.JSONDecodeError:
            continue
        for cand in _from_log(log):
            held = best.get(cand.day)
            if held is None or (stamp_ms(cand.t), cand.kg) > (
                stamp_ms(held.t),
                held.kg,
            ):
                best[cand.day] = cand
    return [best[day] for day in sorted(best)]


def fetch_alarm_logs(client: RemoteStore) -> list[tuple[str, str]]:
    """Every wake-alarm device's raw ``alarm.json``; ``[]`` on any failure.

    Firebase-only (the primary of a mirror client): wake-alarm never
    published weigh-ins to the GitHub mirror.
    """
    store = client.primary if isinstance(client, MirrorSyncClient) else client
    try:
        published = []
        for device in store.list_directory(WAKE_ALARM_DEVICES_DIR):
            text = store.get_file_text(f"{WAKE_ALARM_DEVICES_DIR}/{device}/alarm.json")
            if text is not None:
                published.append((device, text))
    except RemoteSyncError as exc:
        _logger.info("wake-alarm weigh-ins unreadable (%s); skipped", exc)
        return []
    return published
