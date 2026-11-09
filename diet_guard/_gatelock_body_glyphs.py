"""The Body tab's report blocks as glyphs and numbers -- the gate's half.

:mod:`diet_guard._body_report` renders the same :class:`BodyView` as English
sentences for the terminal (``diet_guard body``), and terminal output keeps
its text. The gate is a window kuhy sees, so it gets this text-free twin:
one glyph per concept from :mod:`._gatelock_glyphs`, numbers through the
same ``half_up`` so both surfaces round identically. Method names that only
explained a number (formula names, BMI Prime, Trefethen, the per-formula
ideal weights) are dropped here; the CLI still prints them.
"""

from __future__ import annotations

from datetime import date
from typing import TYPE_CHECKING

from diet_guard import _gatelock_glyphs as g
from diet_guard._activity_kcal import FORMULAS, session_kcal
from diet_guard._body_calc import half_up
from diet_guard._body_energy import MEASURED_PREFIX, MIN_TARGET_KCAL
from diet_guard._body_store import age_on

if TYPE_CHECKING:
    from diet_guard._body_view import BodyView
    from diet_guard._week_plan import WeekPlan

__all__ = [
    "ACTIVITY",
    "activity_glyphs",
    "bmi_glyphs",
    "bmr_glyphs",
    "bodyfat_glyphs",
    "ideal_glyphs",
    "plan_glyphs",
    "profile_glyphs",
    "target_glyphs",
]

_SESSIONS_SHOWN = 10
# Measured-exercise methods: MET keeps its acronym (a DOUBT row in keep.md),
# ACSM's speed equations are a slope, Per-km is its own unit.
METHOD: dict[str, str] = {"MET": "MET", "ACSM": "↗", "Per-km": "/km"}
# The activity picker: a rising bar per level, then the measured methods.
ACTIVITY: dict[str, str] = {
    "sedentary": "▁",
    "light": "▂",
    "moderate": "▄",
    "very": "▆",
    "extra": "█",
    **{f"{MEASURED_PREFIX}{n}": f"{g.MEASURED} {METHOD[n]}" for n in FORMULAS},
}
# Week-plan day sources: logged, typed, still planned, missed.
_SOURCE = {"logged": g.OK, "typed": g.EDIT, "plan": "○", "unlogged": "?"}


def _num(value: float, digits: int = 0) -> str:
    """``value`` rounded half-up to ``digits`` decimals."""
    return f"{half_up(value, digits):.{digits}f}"


def _band(category: str) -> str:
    """The WHO band as a shape: thin, normal, over, obese; dash under 20."""
    for word, glyph in (
        ("thinness", "▽"),
        ("normal", g.OK),
        ("overweight", "△"),
        ("obese", "▲"),
    ):
        if word in category:
            return glyph
    return g.NO_VALUE


def profile_glyphs(view: BodyView, today: date) -> list[str]:
    """Birth date and age, height, sex; then the newest weight."""
    prof = view.profile
    birth = g.NO_VALUE
    if prof.birth is not None:
        age = age_on(date.fromisoformat(prof.birth), today)
        birth = f"{prof.birth} ({age})"
    height = f"{_num(prof.height_cm)} cm" if prof.height_cm else f"{g.NO_VALUE} cm"
    sex = {"m": g.MALE, "f": g.FEMALE}.get(prof.sex or "", g.NO_VALUE)
    newest = max(view.weights) if view.weights else None
    weight = (
        f"{_num(view.weights[newest], 1)} kg  {newest}  {g.TIMES}{len(view.weights)}"
        if newest
        else f"{g.NO_VALUE} kg"
    )
    return [f"{g.BIRTH} {birth}   {height}   {sex}", f"{g.AMOUNT} {weight}"]


def bodyfat_glyphs(view: BodyView) -> list[str]:
    """The newest body-fat reading, or a dash."""
    if not view.body_fats:
        return [f"% {g.NO_VALUE}"]
    day = max(view.body_fats)
    return [f"{_num(view.body_fats[day], 1)}%  {day}  {g.TIMES}{len(view.body_fats)}"]


def bmi_glyphs(view: BodyView) -> list[str]:
    """BMI with its band shape, and the healthy weight range."""
    if view.numbers is None:
        return [f"{g.TAB_BODY} ?"]
    bmi = view.numbers.bmi
    low, high = view.numbers.healthy
    return [
        f"{g.TAB_BODY} {_num(bmi.bmi, 1)} {_band(bmi.category)}",
        f"{g.OK} {_num(low, 1)}{g.DASH}{_num(high, 1)} kg",
    ]


def ideal_glyphs(view: BodyView) -> list[str]:
    """The ideal-weight average and range over every formula."""
    summary = None if view.numbers is None else view.numbers.ideal_summary
    if summary is None:
        return [f"{g.IDEAL} ?"]
    avg, low, high = summary
    return [f"{g.IDEAL} {_num(avg, 1)} kg  ({_num(low, 1)}{g.DASH}{_num(high, 1)})"]


def bmr_glyphs(view: BodyView) -> list[str]:
    """Resting burn: one number per formula that has its inputs."""
    if view.numbers is None:
        return [f"{g.RESTING} ?"]
    values = [_num(f.value) for f in view.numbers.bmr if f.value is not None]
    return [f"{g.RESTING} {'  '.join(values)} kcal"]


def target_glyphs(view: BodyView) -> list[str]:
    """Maintenance burn, and a warning when the target is under the floor."""
    target = None if view.numbers is None else view.numbers.target
    if target is None or target.kcal is None or target.tdee is None:
        return [f"{g.MEASURED} {g.EMPTY}"] if target is not None else ["?"]
    lines = [f"= {_num(target.tdee)} kcal"]
    if target.below_floor:
        lines.append(f"{g.WARN} < {MIN_TARGET_KCAL} kcal")
    return lines


def activity_glyphs(view: BodyView) -> list[str]:
    """Measured means per method, steps, and the newest published workouts."""
    if view.activity_stamp is None and not view.steps:
        return [f"{g.MEASURED} {g.EMPTY}"]
    stamp = (view.activity_stamp or "")[:16].replace("T", " ") or g.NO_VALUE
    lines = [f"{g.SYNC} {stamp}"]
    exercise = view.exercise
    if exercise is not None:
        means = "   ".join(
            f"{METHOD.get(name, name)} {_num(kcal)}"
            for name, kcal in exercise.means.items()
        )
        lines.append(f"{g.AVERAGE} {exercise.days}   {means} kcal")
    if exercise is not None and view.steps:
        newest = max(view.steps)
        extra = _num(exercise.steps_kcal)
        lines.append(f"{g.STEPS} {view.steps[newest]}  {newest}   +{extra} kcal")
    weight = view.weight
    for session in view.sessions[-_SESSIONS_SHOWN:][::-1]:
        km = f" {_num(session.km, 1)} km" if session.km else ""
        kcal = ""
        if weight is not None:
            result = session_kcal(session, weight)
            kcal = "   " + "  ".join(
                f"{METHOD[name]} {_num(result.kcal[name])}" for name in FORMULAS
            )
        # session.kind is the workout's own name, published by the PC: content.
        lines.append(
            f"  {session.day} {session.kind:<8}{_num(session.minutes):>4} min{km}{kcal}"
        )
    return lines


def plan_glyphs(plan: WeekPlan) -> list[str]:
    """The week plan: day of month, kcal, and where the number came from."""
    lines = [f"{g.AVERAGE} {plan.target_avg} kcal"]
    lines.extend(
        f"  {day.day[-2:]}  {day.kcal:>5}  {_SOURCE.get(day.source, '?')}"
        for day in plan.days
    )
    if plan.per_remaining is None:
        lines.append(f"{g.OK} {g.AVERAGE} {_num(plan.week_avg)} kcal")
    else:
        warn = f"  {g.WARN}" if plan.below_floor else ""
        lines.append(f"→ {plan.per_remaining} kcal{warn}")
    return lines
