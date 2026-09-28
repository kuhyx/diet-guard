"""Read a screen-locker manual workout's free text for sport and distance.

A manual entry's sport field is often a generic "other" while the typed text
says "Walking at Ai clearing..." -- and a distance, when there is one, lives
in the prose ("5 km", "5,2km", "3000 m"). Without this, a walk logged by
hand gets only the flat MET estimate even though the user typed its length.

Duration never comes from here: ``duration_minutes`` is a structured field.
"""

from __future__ import annotations

from datetime import datetime, timedelta
import re

from diet_guard._activity_kcal import Session

__all__ = ["logged_window", "manual_session"]

_WALK_RE = re.compile(r"\b(walk|walking|walked|hike|hiking|hiked)\b", re.IGNORECASE)
_RUN_RE = re.compile(r"\b(run|running|ran|jog|jogging|jogged)\b", re.IGNORECASE)
_DISTANCE_RE = re.compile(
    r"(\d+(?:[.,]\d+)?)\s*(km|kilomet(?:er|re)s?|m|met(?:er|re)s?)\b",
    re.IGNORECASE,
)
_METRES_PER_KM = 1000.0
_SPORT_KINDS = {
    "running": "run",
    "walking": "walk",
    "hiking": "walk",
    "cycling": "cycle",
    "biking": "cycle",
    "strength": "strength",
    "gym": "strength",
}


def _text(item: dict[str, object]) -> str:
    """Every free-text field of the entry, joined."""
    return " ".join(str(v) for v in item.values() if isinstance(v, str))


def _kind(item: dict[str, object], text: str) -> str:
    """The sport field if it is specific, else what the prose says."""
    sport = str(item.get("activity_type") or item.get("sport") or "").lower()
    if sport in _SPORT_KINDS:
        return _SPORT_KINDS[sport]
    if _RUN_RE.search(text):
        return "run"
    if _WALK_RE.search(text):
        return "walk"
    return "other"


def _typed_km(item: dict[str, object]) -> float | None:
    """A structured ``distance_km``, when present and numeric."""
    raw = item.get("distance_km")
    try:
        return float(str(raw)) if raw is not None else None
    except ValueError:
        return None


def _text_km(text: str) -> float | None:
    """The first distance written in ``text``, in km, or None."""
    match = _DISTANCE_RE.search(text)
    if match is None:
        return None
    value = float(match.group(1).replace(",", "."))
    in_km = match.group(2).lower().startswith("k")
    return value if in_km else value / _METRES_PER_KM


def logged_window(stamp: object, minutes: float) -> tuple[str | None, str | None]:
    """``(start, end)`` for a workout logged at ``stamp`` as it finished.

    screen-locker stamps a verified workout when it is logged, i.e. at its
    end, so the start is ``minutes`` earlier. Unparsable stamp -> no window.
    """
    try:
        end = datetime.fromisoformat(str(stamp)).astimezone()
    except ValueError:
        return None, None
    start = end - timedelta(minutes=minutes)
    return start.isoformat(timespec="seconds"), end.isoformat(timespec="seconds")


def _clock_window(day: str, item: dict[str, object]) -> tuple[str | None, str | None]:
    """``(start, end)`` from a manual entry's ``HH:MM`` start/end fields."""
    try:
        start = datetime.fromisoformat(f"{day}T{item['start_time']}").astimezone()
        end = datetime.fromisoformat(f"{day}T{item['end_time']}").astimezone()
    except KeyError, ValueError:
        return None, None
    if end < start:  # past midnight
        end += timedelta(days=1)
    return start.isoformat(timespec="seconds"), end.isoformat(timespec="seconds")


def manual_session(
    day: str, item: dict[str, object], minutes: float, label: str
) -> Session:
    """The :class:`Session` one manual workout stands for."""
    text = _text(item)
    kind = _kind(item, text)
    km = _typed_km(item)
    if km is None and kind in {"run", "walk"}:
        km = _text_km(text)
    start, end = _clock_window(day, item)
    return Session(day, kind, minutes, km, label, "screen-locker", start, end)
