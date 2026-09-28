"""Render a :class:`~diet_guard._body_view.BodyView` as aligned text blocks.

One renderer for both surfaces: the CLI prints the blocks, the gate's Body
tab shows each in a monospace panel. Numbers go through ``half_up`` so they
match the phone to the digit.
"""

from __future__ import annotations

from datetime import date
import textwrap
from typing import TYPE_CHECKING

from diet_guard._activity_kcal import (
    FORMULAS,
    METHODS_NOTE,
    session_kcal,
)
from diet_guard._body_calc import BMI_PRIME_NOTE, BROCA_NOTE, TREFETHEN_NOTE, half_up
from diet_guard._body_energy import KCAL_PER_KG, MIN_TARGET_KCAL, activity_label
from diet_guard._body_steps import STEP_BASELINE
from diet_guard._body_store import age_on

if TYPE_CHECKING:
    from diet_guard._body_energy import Goal
    from diet_guard._body_view import BodyView
    from diet_guard._week_plan import WeekPlan

_NAME_W = 24
_COL_W = 15
_SESSIONS_SHOWN = 10
_WRAP = 88
_NEEDS = "Set birth date, height, sex and a weight to see the numbers."


def _wrap(text: str, indent: str = "") -> list[str]:
    """Explanatory prose broken at :data:`_WRAP` columns.

    One unwrapped note once widened the gate's left panel enough to push the
    whole right column off-screen.
    """
    return textwrap.wrap(text, _WRAP, initial_indent=indent, subsequent_indent=indent)


def _num(value: float, digits: int = 0) -> str:
    """``value`` rounded half-up to ``digits`` decimals."""
    return f"{half_up(value, digits):.{digits}f}"


def profile_lines(view: BodyView, today: date) -> list[str]:
    """Who the numbers are for, and what is still missing."""
    prof = view.profile
    birth = "birth date not set"
    if prof.birth is not None:
        age = age_on(date.fromisoformat(prof.birth), today)
        birth = f"born {prof.birth} ({age} y)"
    height = f"{_num(prof.height_cm)} cm" if prof.height_cm else "height not set"
    sex = {"m": "male", "f": "female"}.get(prof.sex or "", "sex not set")
    newest = max(view.weights) if view.weights else None
    weight = (
        f"{_num(view.weights[newest], 1)} kg on {newest} "
        f"({len(view.weights)} weigh-ins)"
        if newest
        else "no weight logged yet"
    )
    return [f"Profile: {birth}, {height}, {sex}", f"Weight:  {weight}"]


def bodyfat_lines(view: BodyView) -> list[str]:
    """The newest body-fat reading and what it switches on."""
    if not view.body_fats:
        return ["Body fat: not logged (log one to use Katch-McArdle)."]
    day = max(view.body_fats)
    return [
        f"Body fat: {_num(view.body_fats[day], 1)}% on {day} "
        f"({len(view.body_fats)} readings) -- targets use Katch-McArdle."
    ]


def bmi_lines(view: BodyView) -> list[str]:
    """BMI with plain-language readings, and the healthy weight range."""
    if view.numbers is None:
        return [_NEEDS]
    bmi = view.numbers.bmi
    low, high = view.numbers.healthy
    return [
        f"BMI {_num(bmi.bmi, 1)} ({bmi.category})",
        f"Healthy weight for your height (BMI 18.5-24.9): "
        f"{_num(low, 1)}-{_num(high, 1)} kg",
        f"BMI Prime {_num(bmi.prime, 2)}   Trefethen {_num(bmi.trefethen, 1)}",
        *_wrap(BMI_PRIME_NOTE, "  "),
        *_wrap(TREFETHEN_NOTE, "  "),
    ]


def ideal_lines(view: BodyView) -> list[str]:
    """Every ideal-weight formula, then their average and range."""
    if view.numbers is None:
        return [_NEEDS]
    lines = ["Ideal weight:"]
    for formula in view.numbers.ideal:
        value = (
            "n/a (< 152 cm)"
            if formula.value is None
            else f"{_num(formula.value, 1)} kg"
        )
        lines.append(f"  {formula.name:<{_NAME_W}}{value}")
    summary = view.numbers.ideal_summary
    if summary is not None:
        avg, low, high = summary
        lines.append(f"  {'Average of all':<{_NAME_W}}{_num(avg, 1)} kg")
        lines.append(f"  {'Ideal range':<{_NAME_W}}{_num(low, 1)}-{_num(high, 1)} kg")
    lines.extend(_wrap(BROCA_NOTE, "  "))
    return lines


def bmr_lines(view: BodyView) -> list[str]:
    """Resting metabolism by formula; body-fat ones wait for a reading."""
    if view.numbers is None:
        return [_NEEDS]
    lines = ["Resting metabolism (kcal/day):"]
    for f in view.numbers.bmr:
        value = "n/a -- log a body-fat %" if f.value is None else _num(f.value)
        lines.append(f"  {f.name:<{_NAME_W + 8}}{value}")
    return lines


def goal_sentence(goal: Goal) -> str:
    """``To lose 0.5 kg / week on Moderate`` -- the goal as words."""
    activity = activity_label(goal.activity)
    if goal.direction == "maintain":
        return f"To maintain on {activity}"
    amount = f"{goal.amount:g} {goal.weight_unit} / {goal.time_unit}"
    return f"To {goal.direction} {amount} on {activity}"


def target_lines(view: BodyView) -> list[str]:
    """The top line: what to eat for the chosen goal, and how it was got."""
    if view.numbers is None:
        return [_NEEDS]
    target = view.numbers.target
    if target.kcal is None or target.tdee is None:
        return [
            f"{goal_sentence(view.goal)}: no workouts published yet "
            "(the PC publishes them on sync)."
        ]
    lines = [f"{goal_sentence(view.goal)} eat {target.kcal} kcal a day."]
    if target.below_floor:
        lines.append(f"  That is below the {MIN_TARGET_KCAL} kcal floor.")
    lines.append(
        f"  Maintenance {_num(target.tdee)} kcal ({target.bmr_name} resting burn "
        f"x activity); 1 kg of fat = {KCAL_PER_KG:g} kcal."
    )
    lines.extend(_wrap("Informational only -- the budget is never changed here.", "  "))
    return lines


def activity_lines(view: BodyView) -> list[str]:
    """Measured exercise averages and the newest published workouts."""
    if view.activity_stamp is None and not view.steps:
        return ["No workouts published yet (the PC publishes them on sync)."]
    stamp = (view.activity_stamp or "")[:16].replace("T", " ") or "not yet"
    lines = [f"Workouts published {stamp}"]
    exercise = view.exercise
    if exercise is not None:
        means = "  ".join(
            f"{name} {_num(kcal)}" for name, kcal in exercise.means.items()
        )
        lines.append(f"Last {exercise.days} full days, net exercise kcal/day: {means}")
    if exercise is not None and view.steps:
        newest = max(view.steps)
        lines.append(
            f"Steps outside workouts: {view.steps[newest]} on {newest}; above "
            f"{STEP_BASELINE}/day they add {_num(exercise.steps_kcal)} kcal/day "
            "(included above)."
        )
    weight = view.weight
    for session in view.sessions[-_SESSIONS_SHOWN:][::-1]:
        km = f" {_num(session.km, 1)} km" if session.km else ""
        kcal = ""
        if weight is not None:
            result = session_kcal(session, weight)
            kcal = "  " + " ".join(
                f"{name[0]}{_num(result.kcal[name])}" for name in FORMULAS
            )
        lines.append(
            f"  {session.day} {session.kind:<8}{_num(session.minutes):>4} min{km}{kcal}"
        )
    lines.extend(_wrap(f"(M = MET, A = ACSM, P = Per-km) {METHODS_NOTE}"))
    return lines


def plan_lines(plan: WeekPlan) -> list[str]:
    """The week plan, one line per day."""
    lines = [f"Week plan for an average of {plan.target_avg} kcal/day:"]
    for day in plan.days:
        note = {"unlogged": "  (no log - type it?)"}.get(day.source, "")
        lines.append(f"  {day.weekday} {day.day}  {day.kcal:>5}  {day.source}{note}")
    if plan.per_remaining is None:
        lines.append(
            f"Every day is known: the week averages {_num(plan.week_avg)} kcal."
        )
    else:
        warn = f" -- below the {MIN_TARGET_KCAL} floor!" if plan.below_floor else ""
        lines.append(f"Eat {plan.per_remaining} kcal on each remaining day{warn}")
    return lines
