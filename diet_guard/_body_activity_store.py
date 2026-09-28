"""The Body document's workout half: published sessions, on disk and back.

Split out of :mod:`diet_guard._body_store` for the 250-line cap. The PC
writes these (:func:`set_activity`, from ``_sync_body.publish_activity``);
every device reads them. Reads are tolerant like the rest of the document.

KEEP IN SYNC WITH ``app/lib/services/body_service.dart``.
"""

from __future__ import annotations

from dataclasses import asdict
from datetime import datetime

from diet_guard._activity_kcal import Session
from diet_guard._body_store import as_number, now_stamp, read_body, write_body

__all__ = ["activity", "session_from_json", "session_to_json", "set_activity"]


def session_to_json(session: Session) -> dict[str, object]:
    """The wire/disk form of one session (short keys, see the docs)."""
    raw = asdict(session)
    return {
        "day": raw["day"],
        "kind": raw["kind"],
        "min": raw["minutes"],
        "km": raw["km"],
        "label": raw["label"],
        "src": raw["source"],
        "start": raw["start"],
        "end": raw["end"],
    }


def _stamp_or_none(value: object) -> str | None:
    """An ISO time string, or None when absent or unparsable."""
    if not isinstance(value, str):
        return None
    try:
        datetime.fromisoformat(value)
    except ValueError:
        return None
    return value


def session_from_json(raw: object) -> Session | None:
    """Parse one stored session, or None when malformed."""
    if not isinstance(raw, dict):
        return None
    day, kind, km_raw = raw.get("day"), raw.get("kind"), raw.get("km")
    minutes, km = as_number(raw.get("min")), as_number(km_raw)
    km_ok = km_raw is None or km is not None
    if not (isinstance(day, str) and isinstance(kind, str) and minutes and km_ok):
        return None
    return Session(
        day=day,
        kind=kind,
        minutes=minutes,
        km=km,
        label=str(raw.get("label", "")),
        source=str(raw.get("src", "")),
        start=_stamp_or_none(raw.get("start")),
        end=_stamp_or_none(raw.get("end")),
    )


def activity() -> tuple[tuple[Session, ...], str | None]:
    """The published sessions and their stamp; ``((), None)`` when none."""
    section = read_body()["activity"]
    stamp = section.get("t")
    raw = section.get("sessions")
    if not isinstance(raw, list) or not isinstance(stamp, str):
        return (), None
    parsed = (session_from_json(item) for item in raw)
    return tuple(s for s in parsed if s is not None), stamp


def set_activity(sessions: tuple[Session, ...]) -> bool:
    """Store ``sessions`` (stamped now) if they differ; True when written."""
    doc = read_body()
    payload = [session_to_json(s) for s in sessions]
    if doc["activity"].get("sessions") == payload:
        return False
    doc["activity"] = {"sessions": payload, "t": now_stamp()}
    write_body(doc)
    return True
