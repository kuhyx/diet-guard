#!/usr/bin/env python3
"""Regenerate the shared cross-language Body-tab parity fixture.

The fixture (``tests/fixtures/body_calc.json``) is read by *both*
``diet_guard/tests/test_body_parity.py`` and
``app/test/services/body_parity_test.dart``: one shared input, one shared
expected result, so the PC and the phone print the same BMI, ideal weights,
calorie table, exercise kcal and week plan for the same person.

``expected`` comes from the Python implementation, the reference the Dart
port must reproduce -- so regenerating blesses whatever Python does now. Only
run it after an intended change, and re-read the diff before committing.

    python3 scripts/build_body_fixture.py
"""

from __future__ import annotations

from dataclasses import asdict
from datetime import date
import json
from pathlib import Path

from diet_guard._activity_kcal import Session, daily_exercise, session_kcal
from diet_guard._body_calc import (
    bmi_report,
    bmr_formulas,
    healthy_range,
    ideal_summary,
    ideal_weights,
    table_bmr,
)
from diet_guard._body_energy import DEFAULT_GOAL, Goal, goal_target
from diet_guard._body_prefs import goal_to_json
from diet_guard._body_steps import step_kcal, stride_m
from diet_guard._budget_biometrics import Biometrics
from diet_guard._week_plan import plan_week

FIXTURE = Path(__file__).resolve().parent.parent / "tests/fixtures/body_calc.json"

_PEOPLE = (
    Biometrics(weight_kg=80.0, height_cm=180.0, age_years=30, is_male=True),
    Biometrics(weight_kg=62.5, height_cm=165.0, age_years=45, is_male=False),
    # Under five feet: the inch-based formulas must come out null.
    Biometrics(weight_kg=50.0, height_cm=150.0, age_years=25, is_male=False),
    # Under 20: adult BMI bands do not apply.
    Biometrics(weight_kg=65.0, height_cm=175.0, age_years=17, is_male=True),
    # Big and heavy: deep into the obese bands, targets far above the floor.
    Biometrics(weight_kg=121.3, height_cm=191.0, age_years=41, is_male=True),
)

_SESSIONS = (
    Session("2026-09-20", "run", 60.5, 5.61, "Running 5.6 km", "runnerup"),
    Session("2026-09-21", "run", 30.0, 7.5, "fast run", "runnerup"),
    Session("2026-09-22", "run", 45.0, 3.0, "slow jog", "runnerup"),
    Session("2026-09-23", "walk", 60.0, 5.0, "walk", "screen-locker"),
    Session("2026-09-24", "walk", 60.0, None, "walk, no distance", "screen-locker"),
    Session("2026-09-25", "strength", 86.2, None, "StrongLifts B", "screen-locker"),
    Session("2026-09-26", "cycle", 40.0, 12.0, "bike", "screen-locker"),
    Session("2026-09-27", "other", 50.0, None, "climbing", "screen-locker"),
    Session("2026-09-19", "walk", 45.0, 3.5, "walked 3500 m", "screen-locker"),
    # Outside the 14-day window for today=2026-09-28: must not count.
    Session("2026-09-13", "run", 60.0, 10.0, "old run", "runnerup"),
    # Today: in progress, must not count either.
    Session("2026-09-28", "run", 60.0, 10.0, "today's run", "runnerup"),
)

_PLANS = (
    # Wednesday: Mon/Tue logged, nothing typed.
    ("2026-09-30", 2000, {"2026-09-28": 2500.4, "2026-09-29": 1800.0}, {}),
    # Typed Saturday feast wins over nothing; typed Monday wins over the log.
    ("2026-09-30", 2000, {"2026-09-28": 2500.0}, {0: 2200, 5: 3500}),
    # Sunday with everything known: no remaining days.
    ("2026-10-04", 1800, {}, dict.fromkeys(range(7), 1900)),
    # Over-eaten early: the rest must go under the floor.
    ("2026-10-01", 1500, {"2026-09-28": 4000, "2026-09-29": 3900}, {}),
)


_BODY_FAT = 18.5


# Goals exercising every direction, unit and activity kind.
_GOALS = (
    DEFAULT_GOAL,
    Goal("gain", 0.25, "kg", "week", "sedentary"),
    Goal("maintain", 0.5, "kg", "week", "extra"),
    Goal("lose", 1.0, "lb", "week", "light"),
    Goal("lose", 500.0, "g", "day", "very"),
    Goal("lose", 0.5, "st", "month", "measured:ACSM"),
    Goal("lose", 12.0, "kg", "year", "measured:Per-km"),
    Goal("lose", 3.0, "kg", "week", "sedentary"),  # far below the floor
)
# Phone-published steps outside workouts (one day under the baseline).
_STEPS = {"2026-09-20": 9000, "2026-09-21": 3500, "2026-09-25": 12000}


def _person(bio: Biometrics) -> dict[str, object]:
    today = date(2026, 9, 28)
    by_day = {day: step_kcal(n, bio) for day, n in _STEPS.items()}
    exercise = daily_exercise(_SESSIONS, bio.weight_kg, today, by_day)
    targets = []
    for fat in (None, _BODY_FAT):
        bmr = table_bmr(bio, fat)
        for goal in _GOALS:
            target = goal_target(goal, bmr.value or 0.0, bmr.name, exercise)
            targets.append(
                {"body_fat_pct": fat, "goal": goal_to_json(goal), **asdict(target)}
            )
    return {
        "bio": asdict(bio),
        "bmi": asdict(bmi_report(bio)),
        "ideal": [[f.name, f.value] for f in ideal_weights(bio)],
        "bmr": [[f.name, f.value] for f in bmr_formulas(bio)],
        "body_fat_pct": _BODY_FAT,
        "bmr_with_fat": [[f.name, f.value] for f in bmr_formulas(bio, _BODY_FAT)],
        "ideal_summary": ideal_summary(ideal_weights(bio)),
        "healthy_range": healthy_range(bio),
        "stride_m": stride_m(bio),
        "step_kcal": {day: step_kcal(n, bio) for day, n in _STEPS.items()},
        "exercise": exercise,
        "exercise_no_steps": daily_exercise(_SESSIONS, bio.weight_kg, today),
        # History younger than 14 days: averaged from its first day.
        "exercise_short": daily_exercise(
            tuple(x for x in _SESSIONS if x.day >= "2026-09-24"), bio.weight_kg, today
        ),
        # Only today's (in-progress) session: no past data, all zero.
        "exercise_today_only": daily_exercise(
            tuple(x for x in _SESSIONS if x.day == "2026-09-28"), bio.weight_kg, today
        ),
        "targets": targets,
    }


def build() -> dict[str, object]:
    """Evaluate every vector against the Python reference."""
    return {
        "today": "2026-09-28",
        "people": [_person(bio) for bio in _PEOPLE],
        "steps": _STEPS,
        "sessions": [asdict(s) for s in _SESSIONS],
        "session_kcal_80kg": [
            {
                "kcal": result.kcal,
                "fallback": sorted(result.fallback),
            }
            for result in (session_kcal(s, 80.0) for s in _SESSIONS)
        ],
        "plans": [
            {
                "today": today,
                "target": target,
                "logged": logged,
                "typed": {str(k): v for k, v in typed.items()},
                "expected": asdict(
                    plan_week(date.fromisoformat(today), target, logged, typed)
                ),
            }
            for today, target, logged, typed in _PLANS
        ],
    }


def main() -> None:
    """Write the fixture."""
    FIXTURE.write_text(json.dumps(build(), indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
