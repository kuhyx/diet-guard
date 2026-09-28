"""Collect the last weeks' workouts from RunnerUp and screen-locker.

PC-only: both sources live on this machine. The result is published into
the Body document (``_body_store.set_activity``) so the phone shows the same
sessions. Dedup rules, so one workout counts once (``docs/DOCS-body.md``):

* RunnerUp TCX files are the source for runs; screen-locker's
  ``runnerup_verified`` entry for a day is used only when no TCX exists for it.
* ``phone_verified`` is the phone's report of the same StrongLifts session the
  PC logs as ``pc_workout_verified``; it counts only on a day without one.

Both sources are optional and read defensively: a missing ``screen_locker``
package, an unreadable log, or a malformed TCX drops that source (or file),
never the tick.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta
from importlib import import_module
import logging
from pathlib import Path
import re
from xml.etree.ElementTree import ParseError

from defusedxml.ElementTree import parse as parse_xml

from diet_guard._activity_kcal import Session
from diet_guard._manual_workout_parse import logged_window, manual_session

_logger = logging.getLogger(__name__)

RUNNERUP_DIRS: tuple[Path, ...] = (
    Path.home() / "data/cloud/RunnerUp",
    Path.home() / "data/cloud/RunnerUp/processed",
)
WINDOW_DAYS = 28
_TCX_NS = {"t": "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"}
# "Auto-scanned: Running: 5.6 km in 60 min" -- the sport sits between colons.
_AUTO_SCAN_COLONS = 2
_MINUTES_RE = re.compile(r"\((\d+(?:\.\d+)?) min")
_SPORT_KINDS = {
    "running": "run",
    "run": "run",
    "walking": "walk",
    "walk": "walk",
    "hiking": "walk",
    "biking": "cycle",
    "cycling": "cycle",
    "stationary bike": "cycle",
    "strength": "strength",
    "gym": "strength",
    "weights": "strength",
}


def _kind(name: object) -> str:
    """Map a sport/activity name onto a :class:`Session` kind."""
    return _SPORT_KINDS.get(str(name).strip().lower(), "other")


def _tcx_session(path: Path) -> tuple[str, Session] | None:
    """``(activity id, session)`` from one TCX file, or None if unusable."""
    try:
        root = parse_xml(path).getroot()
    except (ParseError, OSError) as exc:
        _logger.warning("Unreadable TCX %s (%s); skipped", path, exc)
        return None
    activity = root.find("t:Activities/t:Activity", _TCX_NS)
    ident = activity.findtext("t:Id", "", _TCX_NS) if activity is not None else ""
    if activity is None or not ident:
        return None
    seconds = metres = 0.0
    for lap in activity.findall("t:Lap", _TCX_NS):
        seconds += float(lap.findtext("t:TotalTimeSeconds", "0", _TCX_NS))
        metres += float(lap.findtext("t:DistanceMeters", "0", _TCX_NS))
    started = datetime.fromisoformat(ident).astimezone()
    sport = activity.get("Sport", "Other")
    session = Session(
        day=started.date().isoformat(),
        kind=_kind(sport),
        minutes=seconds / 60.0,
        km=metres / 1000.0 if metres > 0 else None,
        label=f"{sport} {metres / 1000:.1f} km",
        source="runnerup",
        start=started.isoformat(timespec="seconds"),
        end=(started + timedelta(seconds=seconds)).isoformat(timespec="seconds"),
    )
    return ident, session


def runnerup_sessions(since: str) -> list[Session]:
    """Every TCX session on or after ``since``, once per activity id."""
    found: dict[str, Session] = {}
    for folder in RUNNERUP_DIRS:
        for path in sorted(folder.glob("*.tcx")) if folder.is_dir() else []:
            parsed = _tcx_session(path)
            if parsed is not None and parsed[1].day >= since:
                found.setdefault(parsed[0], parsed[1])
    return sorted(found.values(), key=lambda s: s.day)


def screen_locker_log_file() -> Path | None:
    """screen-locker's ``log.json``, or None when the package is absent."""
    try:
        package = import_module("screen_locker")
    except ImportError:
        return None
    path = Path(str(package.__file__)).parent / "log.json"
    return path if path.is_file() else None


def _minutes(data: dict[str, object]) -> float | None:
    """A workout's duration from ``duration_minutes`` or its ``(N min`` text."""
    raw = data.get("duration_minutes")
    if raw is not None:
        try:
            return float(str(raw))
        except ValueError:
            pass
    # phone_verified entries carry no duration field, only "(86 min" prose.
    match = _MINUTES_RE.search(str(data.get("source", "")))
    return float(match.group(1)) if match else None


def _km(data: dict[str, object]) -> float | None:
    """``distance_km`` when present and numeric."""
    try:
        return float(str(data["distance_km"]))
    except KeyError, ValueError:
        return None


def _day_sessions(
    day: str, entries: list[dict[str, object]], tcx_days: set[str]
) -> list[Session]:
    """The sessions one screen-locker day contributes, after dedup."""
    pairs = [(e, e.get("workout_data")) for e in entries]
    items = [(e, d) for e, d in pairs if isinstance(d, dict)]
    types = {d.get("type") for _, d in items}
    out: list[Session] = []
    for entry, item in items:
        kind_type = item.get("type")
        minutes = _minutes(item)
        if minutes is None or minutes <= 0:
            continue
        label = str(item.get("source", kind_type))
        if kind_type == "pc_workout_verified" or (
            kind_type == "phone_verified" and "pc_workout_verified" not in types
        ):
            start, end = logged_window(entry.get("timestamp"), minutes)
            out.append(
                Session(
                    day, "strength", minutes, None, label, "screen-locker", start, end
                )
            )
        elif kind_type == "manual_workout":
            out.append(manual_session(day, item, minutes, label))
        elif kind_type == "runnerup_verified" and day not in tcx_days:
            sport = (
                label.split(":")[1]
                if label.count(":") >= _AUTO_SCAN_COLONS
                else "Running"
            )
            out.append(
                Session(day, _kind(sport), minutes, _km(item), label, "screen-locker")
            )
    return out


def screen_locker_sessions(since: str, tcx_days: set[str]) -> list[Session]:
    """Sessions from screen-locker's log on or after ``since``; [] if absent."""
    path = screen_locker_log_file()
    if path is None:
        return []
    try:
        log_io = import_module("screen_locker._log_io")
        log = log_io.load_workout_log(path)
    except (ImportError, AttributeError) as exc:
        _logger.warning("screen-locker log unreadable (%s); skipped", exc)
        return []
    sessions: list[Session] = []
    for day in sorted(log):
        if day >= since:
            sessions.extend(_day_sessions(day, log[day], tcx_days))
    return sessions


def collect_sessions(today: date) -> tuple[Session, ...]:
    """Every workout in the last :data:`WINDOW_DAYS`, deduplicated, by day."""
    since = (today - timedelta(days=WINDOW_DAYS)).isoformat()
    runs = runnerup_sessions(since)
    others = screen_locker_sessions(since, {s.day for s in runs})
    return tuple(sorted(runs + others, key=lambda s: (s.day, s.kind, s.minutes)))


def sources_available() -> bool:
    """Whether this machine has any workout source at all.

    Guards publishing: a device with neither RunnerUp's folder nor
    screen-locker would otherwise publish an empty list over the real one.
    """
    return any(folder.is_dir() for folder in RUNNERUP_DIRS) or (
        screen_locker_log_file() is not None
    )
