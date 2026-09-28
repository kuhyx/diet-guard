"""Python half of the Body parity gate: every formula against the fixture.

``tests/fixtures/body_calc.json`` is generated from this implementation by
``scripts/build_body_fixture.py`` and asserted value-for-value by the Dart
suite too (``app/test/services/body_parity_test.dart``). This half guards the
fixture against drifting from the code it claims to describe.
"""

from __future__ import annotations

from dataclasses import asdict
from datetime import date
import json
from pathlib import Path

import pytest

from diet_guard._activity_kcal import Session, daily_exercise, session_kcal
from diet_guard._body_calc import (
    bmi_report,
    bmr_formulas,
    healthy_range,
    ideal_summary,
    ideal_weights,
    table_bmr,
)
from diet_guard._body_energy import goal_target
from diet_guard._body_prefs import goal_from_json
from diet_guard._body_steps import step_kcal, stride_m
from diet_guard._budget_biometrics import Biometrics
from diet_guard._week_plan import plan_week

_FIXTURE = Path(__file__).resolve().parents[2] / "tests/fixtures/body_calc.json"
_DATA = json.loads(_FIXTURE.read_text(encoding="utf-8"))
_TODAY = date.fromisoformat(_DATA["today"])
_SESSIONS = tuple(Session(**raw) for raw in _DATA["sessions"])


def _same(actual: object, expected: object) -> None:
    """Deep equality with float tolerance (JSON turns tuples into lists)."""
    if isinstance(expected, float) or isinstance(actual, float):
        assert actual == pytest.approx(expected, rel=1e-12, abs=1e-9)
    elif isinstance(expected, dict):
        assert isinstance(actual, dict)
        assert set(actual) == set(expected)
        for key, value in expected.items():
            _same(actual[key], value)
    elif isinstance(expected, list):
        assert isinstance(actual, (list, tuple))
        assert len(actual) == len(expected)
        for got, want in zip(actual, expected, strict=True):
            _same(got, want)
    else:
        assert actual == expected


@pytest.mark.parametrize("person", _DATA["people"], ids=lambda p: str(p["bio"]))
def test_person_matches_the_fixture(person: dict[str, object]) -> None:
    bio = Biometrics(**person["bio"])  # type-checked by the dataclass itself
    fat = person["body_fat_pct"]
    steps = {day: step_kcal(n, bio) for day, n in _DATA["steps"].items()}
    _same(asdict(bmi_report(bio)), person["bmi"])
    _same([[f.name, f.value] for f in ideal_weights(bio)], person["ideal"])
    _same([[f.name, f.value] for f in bmr_formulas(bio)], person["bmr"])
    _same([[f.name, f.value] for f in bmr_formulas(bio, fat)], person["bmr_with_fat"])
    _same(ideal_summary(ideal_weights(bio)), person["ideal_summary"])
    _same(healthy_range(bio), person["healthy_range"])
    _same(stride_m(bio), person["stride_m"])
    _same(steps, person["step_kcal"])
    exercise = daily_exercise(_SESSIONS, bio.weight_kg, _TODAY, steps)
    _same(exercise, person["exercise"])
    _same(daily_exercise(_SESSIONS, bio.weight_kg, _TODAY), person["exercise_no_steps"])
    short = tuple(s for s in _SESSIONS if s.day >= "2026-09-24")
    _same(daily_exercise(short, bio.weight_kg, _TODAY), person["exercise_short"])
    only_today = tuple(s for s in _SESSIONS if s.day == "2026-09-28")
    _same(
        daily_exercise(only_today, bio.weight_kg, _TODAY),
        person["exercise_today_only"],
    )
    for row in person["targets"]:
        bmr = table_bmr(bio, row["body_fat_pct"])
        target = goal_target(
            goal_from_json(row["goal"]), bmr.value or 0.0, bmr.name, exercise
        )
        expected = {k: v for k, v in row.items() if k not in {"goal", "body_fat_pct"}}
        _same(asdict(target), expected)


def test_session_kcal_matches_the_fixture() -> None:
    for session, expected in zip(_SESSIONS, _DATA["session_kcal_80kg"], strict=True):
        result = session_kcal(session, 80.0)
        _same(result.kcal, expected["kcal"])
        assert sorted(result.fallback) == expected["fallback"]


@pytest.mark.parametrize("plan", _DATA["plans"], ids=lambda p: p["today"])
def test_week_plans_match_the_fixture(plan: dict[str, object]) -> None:
    typed = {int(k): v for k, v in plan["typed"].items()}
    result = plan_week(
        date.fromisoformat(plan["today"]), plan["target"], plan["logged"], typed
    )
    _same(asdict(result), plan["expected"])
