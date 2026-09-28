"""Exercise energy per workout, by every formula the workout data supports.

Pure arithmetic over :class:`Session` values; where sessions come from is
:mod:`diet_guard._activity_sources`. Mirrored in
``app/lib/services/activity_kcal.dart`` and gated by the shared
``tests/fixtures/body_calc.json``.

Every formula returns **net** kcal -- energy above resting. The measured
TDEE adds exercise on top of ``BMR x 1.2``, which already pays for the resting
hour, so a gross figure would count it twice.

* **MET** (Ainsworth 2011 Compendium): ``(MET - 1) x kg x hours``. Running and
  walking read MET off the Compendium's speed table (linear between rows);
  lifting is code 02052 (resistance training, squats) = 5.0 -- between
  02054 (multiple exercises, 8-15 reps, 3.5) and 02050 (power lifting,
  vigorous, 6.0), since a 5x5 session is mostly rest between heavy sets.
* **ACSM** metabolic equations, level ground: VO2 = 0.2 v + 3.5 (running) or
  0.1 v + 3.5 (walking), v in m/min; net kcal = (VO2 - 3.5) x kg x min x 5/1000.
* **Per-km**: running ~0.9 kcal/kg/km net (the classic "1 kcal/kg/km" is
  gross), walking ~0.5 kcal/kg/km net.

ACSM and per-km need a distance, so they only exist for runs and walks that
carry one; every other session falls back to its MET figure (``fallback``) so
all three daily totals cover the same workouts.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
import itertools

__all__ = [
    "FORMULAS",
    "METHODS_NOTE",
    "WINDOW_DAYS",
    "Session",
    "SessionKcal",
    "daily_exercise",
    "met_for",
    "session_kcal",
    "window_days",
]

FORMULAS: tuple[str, ...] = ("MET", "ACSM", "Per-km")
# Shown under the Activity panel on both surfaces.
METHODS_NOTE = (
    "MET = standard activity values x your weight x time. "
    "ACSM = American College of Sports Medicine running/walking equation from "
    "your speed. Per-km = ~0.9 kcal per kg per km running, ~0.5 walking. "
    "All are energy above resting."
)
# Measured activity averages the last two full weeks.
WINDOW_DAYS = 14

_RUN_MET_BY_KMH: tuple[tuple[float, float], ...] = (
    (6.4, 6.0),
    (8.0, 8.3),
    (8.4, 9.0),
    (9.7, 9.8),
    (10.8, 10.5),
    (11.3, 11.0),
    (12.1, 11.5),
    (12.9, 11.8),
    (13.8, 12.3),
    (14.5, 12.8),
    (16.1, 14.5),
    (17.7, 16.0),
    (19.3, 19.0),
    (20.9, 19.8),
    (22.5, 23.0),
)
_WALK_MET_BY_KMH: tuple[tuple[float, float], ...] = (
    (3.2, 2.8),
    (4.0, 3.0),
    (4.8, 3.5),
    (5.6, 4.3),
    (6.4, 5.0),
    (7.2, 7.0),
    (8.0, 8.3),
)
# Compendium codes: 02052 resistance training, 12150 running general,
# 17200 walking general-ish, 01015 bicycling general, generic moderate.
_FIXED_MET = {"strength": 5.0, "run": 8.0, "walk": 3.5, "cycle": 7.5, "other": 4.0}
_ACSM_SLOPE = {"run": 0.2, "walk": 0.1}
_NET_KCAL_PER_KG_KM = {"run": 0.9, "walk": 0.5}
_KCAL_PER_LITRE_O2 = 5.0


@dataclass(frozen=True)
class Session:
    """One workout, reduced to what the energy formulas need.

    Attributes:
        day: Local ``YYYY-MM-DD`` the workout happened on.
        kind: ``strength``, ``run``, ``walk``, ``cycle`` or ``other``.
        minutes: Duration.
        km: Distance, or None when the source has none.
        label: Human description for the list.
        source: Where it came from (``runnerup``, ``screen-locker``).
        start: Local ISO start time, when the source knows it.
        end: Local ISO end time, when the source knows it. The phone drops
            Health Connect steps inside ``start..end`` so a walk is not
            counted as both a workout and steps.
    """

    day: str
    kind: str
    minutes: float
    km: float | None
    label: str
    source: str
    start: str | None = None
    end: str | None = None


@dataclass(frozen=True)
class SessionKcal:
    """Net kcal of one session per formula; ``fallback`` names MET stand-ins."""

    session: Session
    kcal: dict[str, float]
    fallback: frozenset[str]


def _interpolate(table: tuple[tuple[float, float], ...], kmh: float) -> float:
    """Linear interpolation of MET at ``kmh``, clamped to the table's ends."""
    if kmh <= table[0][0]:
        return table[0][1]
    for (x0, y0), (x1, y1) in itertools.pairwise(table):
        if kmh <= x1:
            return y0 + (y1 - y0) * (kmh - x0) / (x1 - x0)
    return table[-1][1]


def _speed_kmh(session: Session) -> float | None:
    """Average speed, or None without a usable distance and duration."""
    if session.km is None or session.km <= 0 or session.minutes <= 0:
        return None
    return session.km / (session.minutes / 60.0)


def met_for(session: Session) -> float:
    """The MET value for ``session``: speed-based when possible, else fixed."""
    kmh = _speed_kmh(session)
    if kmh is not None and session.kind == "run":
        return _interpolate(_RUN_MET_BY_KMH, kmh)
    if kmh is not None and session.kind == "walk":
        return _interpolate(_WALK_MET_BY_KMH, kmh)
    return _FIXED_MET.get(session.kind, _FIXED_MET["other"])


def session_kcal(session: Session, weight_kg: float) -> SessionKcal:
    """Net kcal of ``session`` for a ``weight_kg`` person, by every formula."""
    hours = session.minutes / 60.0
    met = (met_for(session) - 1.0) * weight_kg * hours
    kcal = {"MET": met, "ACSM": met, "Per-km": met}
    fallback = {"ACSM", "Per-km"}
    kmh = _speed_kmh(session)
    if kmh is not None and session.km is not None and session.kind in _ACSM_SLOPE:
        metres_per_min = kmh * 1000.0 / 60.0
        net_vo2 = _ACSM_SLOPE[session.kind] * metres_per_min
        kcal["ACSM"] = net_vo2 * weight_kg * session.minutes * _KCAL_PER_LITRE_O2 / 1000
        kcal["Per-km"] = _NET_KCAL_PER_KG_KM[session.kind] * weight_kg * session.km
        fallback.clear()
    return SessionKcal(session=session, kcal=kcal, fallback=frozenset(fallback))


def daily_exercise(
    sessions: tuple[Session, ...],
    weight_kg: float,
    today: date,
    extra_by_day: dict[str, float] | None = None,
) -> dict[str, float]:
    """Mean net exercise kcal per day over the last :data:`WINDOW_DAYS`.

    Only full past days count: today is still in progress, so the window
    ends yesterday. It starts :data:`WINDOW_DAYS` days back -- or, while the
    data is younger than that, on the first day that has any, so a week of
    history is averaged over that week rather than diluted over 14 days. The
    denominator is calendar days within that span: a rest day burns no
    exercise kcal, which is exactly what a daily average must reflect. With
    no past data at all, every formula reads 0.

    ``extra_by_day`` (day -> net kcal, e.g. steps outside workouts) is added
    to every formula alike: it is not a workout any formula could measure.
    """
    extra = extra_by_day or {}
    span = window_days(sessions, today, extra)
    totals = dict.fromkeys(FORMULAS, 0.0)
    if not span:
        return totals
    first = (today - timedelta(days=span)).isoformat()
    last = today.isoformat()
    for session in sessions:
        if first <= session.day < last:
            for name, value in session_kcal(session, weight_kg).kcal.items():
                totals[name] += value
    for day, kcal in extra.items():
        if first <= day < last:
            for name in totals:
                totals[name] += kcal
    return {name: total / span for name, total in totals.items()}


def window_days(
    sessions: tuple[Session, ...],
    today: date,
    extra_by_day: dict[str, float] | None = None,
) -> int:
    """How many full past days :func:`daily_exercise` averages over.

    :data:`WINDOW_DAYS`, or fewer while the earliest past data (a session or
    an ``extra_by_day`` key before ``today``) is younger than that; 0 when
    there is no past data at all.
    """
    last = today.isoformat()
    days = [s.day for s in sessions if s.day < last]
    days += [d for d in (extra_by_day or {}) if d < last]
    if not days:
        return 0
    return min((today - date.fromisoformat(min(days))).days, WINDOW_DAYS)
