"""CLI for the Body feature: ``body``, ``weight``, ``profile``, ``plan-week``.

Split out of :mod:`diet_guard._cli` for the 250-line cap. Everything shown is
informational; nothing here writes the daily budget. The one budget-record
field touched is ``w`` (body weight, feeding the protein target), and only
when the typed weigh-in is the newest one.

Edits publish straight away (``publish_after_log``), for the same reason a
logged meal does: until the full tick runs, the phone shows stale data.
"""

from __future__ import annotations

import argparse
from dataclasses import replace
from datetime import date
from typing import TYPE_CHECKING

from diet_guard._body_energy import (
    ACTIVITY_CHOICES,
    DIRECTIONS,
    TIME_UNITS,
    WEIGHT_UNITS,
    Goal,
)
from diet_guard._body_fat_store import (
    MAX_BODY_FAT,
    MIN_BODY_FAT,
    body_fats,
    set_body_fat,
)
from diet_guard._body_prefs import saved_goal, set_goal
from diet_guard._body_report import (
    activity_lines,
    bmi_lines,
    bmr_lines,
    bodyfat_lines,
    ideal_lines,
    plan_lines,
    profile_lines,
    target_lines,
)
from diet_guard._body_store import (
    MAX_KG,
    MIN_KG,
    newest_weight,
    set_profile,
    set_weight,
    weights,
)
from diet_guard._body_view import budget_or_default, build_view
from diet_guard._daystatus import day_total_kcal
from diet_guard._phone_weight import update_weight
from diet_guard._state import load_log, now_local
from diet_guard._sync_events import publish_after_log
from diet_guard._week_plan import WEEKDAYS, plan_week

if TYPE_CHECKING:
    from collections.abc import Callable

_WEIGHT_LIST = 14


def _iso_date(text: str) -> str:
    """Argparse type: a ``YYYY-MM-DD`` date, normalised."""
    try:
        return date.fromisoformat(text).isoformat()
    except ValueError as exc:
        msg = f"not a YYYY-MM-DD date: {text!r}"
        raise argparse.ArgumentTypeError(msg) from exc


def _day_kcal(text: str) -> tuple[int, int]:
    """Argparse type: ``mon=2500`` -> ``(0, 2500)``."""
    name, _, kcal = text.partition("=")
    names = [w.lower() for w in WEEKDAYS]
    if name.lower()[:3] not in names or not kcal.isdigit():
        msg = f"expected e.g. mon=2500, got {text!r}"
        raise argparse.ArgumentTypeError(msg)
    return names.index(name.lower()[:3]), int(kcal)


def register_body_subparsers(sub: argparse._SubParsersAction) -> None:
    """Register ``body``, ``weight``, ``profile`` and ``plan-week``."""
    body = sub.add_parser("body", help="Calorie target, BMI, ideal weight, workouts.")
    body.add_argument("--direction", choices=DIRECTIONS, help="lose, maintain or gain.")
    body.add_argument("--amount", type=float, help="how much, e.g. 0.5.")
    body.add_argument(
        "--weight-unit", choices=list(WEIGHT_UNITS), help="kg, lb, g, st."
    )
    body.add_argument("--time-unit", choices=list(TIME_UNITS), help="per day/week/...")
    body.add_argument("--activity", choices=ACTIVITY_CHOICES, help="activity level.")
    body.add_argument("--save", action="store_true", help="remember this goal.")
    fat = sub.add_parser("bodyfat", help="Log (or list) body fat %%.")
    fat.add_argument("pct", nargs="?", type=float, help="body fat in %%.")
    fat.add_argument("--date", type=_iso_date, help="day (default today).")
    fat.add_argument("--delete", action="store_true", help="delete that day.")
    weight = sub.add_parser("weight", help="Log (or list) body weight.")
    weight.add_argument("kg", nargs="?", type=float, help="weight in kg.")
    weight.add_argument("--date", type=_iso_date, help="day (default today).")
    weight.add_argument("--delete", action="store_true", help="delete that day.")
    prof = sub.add_parser("profile", help="Set birth date, height and sex.")
    prof.add_argument("--birth", type=_iso_date, help="YYYY-MM-DD.")
    prof.add_argument("--height", type=float, help="height in cm.")
    prof.add_argument("--sex", choices=("m", "f"), help="for the BMR constant.")
    plan = sub.add_parser(
        "plan-week", help="kcal per remaining day for a weekly average."
    )
    plan.add_argument("--target", type=int, help="average kcal/day (default: budget).")
    plan.add_argument(
        "--day", type=_day_kcal, action="append", default=[], help="mon=2500"
    )


def _publish(emit: Callable[[str], None]) -> None:
    """Push the edit now, reporting (not raising) an outage."""
    failure = publish_after_log()
    if failure is not None:
        emit(f"saved locally, not yet published ({failure}).")


def _goal(args: argparse.Namespace) -> Goal:
    """The saved goal with any typed part replaced."""
    goal = saved_goal()
    parts = {
        "direction": args.direction,
        "amount": args.amount,
        "weight_unit": args.weight_unit,
        "time_unit": args.time_unit,
        "activity": args.activity,
    }
    return replace(goal, **{k: v for k, v in parts.items() if v is not None})


def cmd_body(emit: Callable[[str], None], args: argparse.Namespace) -> int:
    """Print every Body block: the target first, profile and body fat last.

    The profile is set up once, so it sits at the bottom -- unless something
    in it is missing, when it comes first so the gap is the first thing seen.
    """
    today = now_local().date()
    goal = _goal(args)
    if args.save:
        set_goal(goal)
        emit("goal saved.")
    view = build_view(today, goal)
    blocks = [
        target_lines(view),
        bmi_lines(view),
        ideal_lines(view),
        bmr_lines(view),
        activity_lines(view),
    ]
    profile = profile_lines(view, today)
    blocks = [profile, *blocks] if not view.profile.complete else [*blocks, profile]
    blocks.append(bodyfat_lines(view))
    for block in blocks:
        for line in block:
            emit(line)
        emit("")
    return 0


def cmd_bodyfat(emit: Callable[[str], None], args: argparse.Namespace) -> int:
    """Log, delete or list body-fat readings."""
    day = args.date or now_local().date().isoformat()
    if args.pct is None and not args.delete:
        for when, pct in list(body_fats().items())[-_WEIGHT_LIST:]:
            emit(f"{when}  {pct:.1f}%")
        return 0
    if args.pct is not None and not MIN_BODY_FAT <= args.pct <= MAX_BODY_FAT:
        emit(f"body fat must be between {MIN_BODY_FAT:g} and {MAX_BODY_FAT:g} %.")
        return 1
    set_body_fat(day, None if args.delete else args.pct)
    emit(f"{'deleted' if args.delete else f'{args.pct:g}%'} for {day}.")
    _publish(emit)
    return 0


def cmd_weight(emit: Callable[[str], None], args: argparse.Namespace) -> int:
    """Log, delete or list weigh-ins."""
    day = args.date or now_local().date().isoformat()
    if args.kg is None and not args.delete:
        for when, kg in list(weights().items())[-_WEIGHT_LIST:]:
            emit(f"{when}  {kg:.1f} kg")
        return 0
    if args.kg is not None and not MIN_KG <= args.kg <= MAX_KG:
        emit(f"weight must be between {MIN_KG:g} and {MAX_KG:g} kg.")
        return 1
    set_weight(day, None if args.delete else args.kg)
    newest = newest_weight()
    # Editing (or deleting) the newest day moves ``w``; an older day does not.
    if newest is not None and day >= newest[0]:
        update_weight(newest[1])
    emit(f"{'deleted' if args.delete else f'{args.kg:g} kg'} for {day}.")
    _publish(emit)
    return 0


def cmd_profile(emit: Callable[[str], None], args: argparse.Namespace) -> int:
    """Set any of birth/height/sex."""
    fields = {
        name: value
        for name, value in (
            ("birth", args.birth),
            ("height_cm", args.height),
            ("sex", args.sex),
        )
        if value is not None
    }
    if not fields:
        emit(profile_lines(build_view(now_local().date()), now_local().date())[0])
        return 0
    set_profile(**fields)
    emit("profile saved.")
    _publish(emit)
    return 0


def cmd_plan_week(emit: Callable[[str], None], args: argparse.Namespace) -> int:
    """Print the week plan."""
    log = load_log()
    plan = plan_week(
        now_local().date(),
        args.target or budget_or_default(),
        {day: day_total_kcal(log, day) for day in log},
        dict(args.day),
    )
    for line in plan_lines(plan):
        emit(line)
    return 0
