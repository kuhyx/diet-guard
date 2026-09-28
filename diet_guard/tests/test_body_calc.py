"""Edge cases of the Body formulas the shared parity fixture does not reach."""

from __future__ import annotations

from datetime import date

import pytest

from diet_guard._activity_kcal import (
    Session,
    daily_exercise,
    met_for,
    session_kcal,
    window_days,
)
from diet_guard._body_calc import (
    bmi_report,
    bmr_formulas,
    half_up,
    ideal_summary,
    table_bmr,
)
from diet_guard._body_energy import (
    MEASURED_PREFIX,
    Goal,
    Target,
    activity_label,
    goal_target,
)
from diet_guard._budget_biometrics import Biometrics
from diet_guard._week_plan import plan_week, week_start

_MAN = Biometrics(weight_kg=80.0, height_cm=180.0, age_years=30, is_male=True)
_TODAY = date(2026, 9, 28)


def _session(
    day: str, kind: str = "run", minutes: float = 60.0, km: float | None = 10.0
) -> Session:
    return Session(day, kind, minutes, km, "x", "runnerup")


class TestHalfUp:
    def test_rounds_halves_up_unlike_python_round(self) -> None:
        assert half_up(2.5) == 3
        assert round(2.5) == 2
        assert half_up(1.25, 1) == 1.3


class TestBmiCategory:
    @pytest.mark.parametrize(
        ("kg", "label"),
        [
            (45.0, "severe thinness"),
            (52.0, "moderate thinness"),
            (58.0, "mild thinness"),
            (70.0, "normal"),
            (90.0, "overweight"),
            (100.0, "obese class I"),
            (120.0, "obese class II"),
            (140.0, "obese class III"),
        ],
    )
    def test_every_who_band(self, kg: float, label: str) -> None:
        bio = Biometrics(weight_kg=kg, height_cm=180.0, age_years=30, is_male=True)
        assert bmi_report(bio).category == label


class TestBmr:
    def test_body_fat_formulas_are_none_without_a_reading(self) -> None:
        names = {f.name: f.value for f in bmr_formulas(_MAN)}
        assert names["Katch-McArdle"] is None
        assert names["Cunningham"] is None

    def test_table_bmr_switches_to_katch_mcardle_with_body_fat(self) -> None:
        assert table_bmr(_MAN, None).name == "Mifflin-St Jeor"
        lean = table_bmr(_MAN, 20.0)
        assert lean.name == "Katch-McArdle"
        assert lean.value == pytest.approx(370 + 21.6 * 64.0)

    def test_ideal_summary_is_none_when_nothing_applies(self) -> None:
        assert ideal_summary(()) is None


class TestGoal:
    def test_kg_per_day_signs(self) -> None:
        assert Goal("lose", 0.7, "kg", "week", "light").kg_per_day() == pytest.approx(
            0.1
        )
        assert Goal("gain", 0.7, "kg", "week", "light").kg_per_day() == pytest.approx(
            -0.1
        )
        assert Goal("maintain", 5.0, "kg", "day", "light").kg_per_day() == 0.0

    def test_unknown_activity_has_no_target(self) -> None:
        target = goal_target(Goal("lose", 1, "kg", "week", "bogus"), 1800, "M", None)
        assert target == Target(kcal=None, tdee=None, bmr_name="M")
        assert not target.below_floor

    def test_measured_needs_that_formula(self) -> None:
        goal = Goal("lose", 1, "kg", "week", f"{MEASURED_PREFIX}MET")
        assert goal_target(goal, 1800, "M", None).kcal is None
        assert goal_target(goal, 1800, "M", {"ACSM": 100.0}).kcal is None
        assert goal_target(goal, 1800, "M", {"MET": 100.0}).tdee == pytest.approx(2260)

    def test_below_floor(self) -> None:
        target = goal_target(
            Goal("lose", 2, "kg", "week", "sedentary"), 1500, "M", None
        )
        assert target.below_floor

    def test_activity_labels(self) -> None:
        assert activity_label("moderate") == "Moderate"
        assert activity_label(f"{MEASURED_PREFIX}ACSM") == "Measured (ACSM)"
        assert activity_label("mystery") == "mystery"


class TestSessions:
    def test_met_is_clamped_at_both_ends_of_the_speed_table(self) -> None:
        assert met_for(_session("d", km=1.0)) == 6.0  # 1 km/h
        assert met_for(_session("d", km=40.0)) == 23.0  # 40 km/h
        assert met_for(_session("d", kind="walk", km=2.0)) == 2.8
        assert met_for(_session("d", kind="walk", km=100.0)) == 8.3

    def test_fixed_mets_without_a_distance(self) -> None:
        assert met_for(_session("d", kind="cycle", km=None)) == 7.5
        assert met_for(_session("d", kind="yoga", km=None)) == 4.0
        assert met_for(_session("d", minutes=0.0)) == 8.0

    def test_no_distance_falls_back_to_met(self) -> None:
        result = session_kcal(_session("d", kind="walk", km=None), 70.0)
        assert result.fallback == {"ACSM", "Per-km"}
        assert len(set(result.kcal.values())) == 1


class TestWindow:
    def test_full_window_once_history_is_old_enough(self) -> None:
        assert window_days((_session("2026-09-01"),), _TODAY) == 14

    def test_short_history_counts_from_its_first_day(self) -> None:
        assert window_days((_session("2026-09-25"),), _TODAY) == 3
        extra = {"2026-09-26": 50.0}
        assert window_days((), _TODAY, extra) == 2

    def test_today_never_counts(self) -> None:
        assert window_days((_session("2026-09-28"),), _TODAY) == 0
        zero = daily_exercise((_session("2026-09-28"),), 80.0, _TODAY)
        assert zero == {"MET": 0.0, "ACSM": 0.0, "Per-km": 0.0}

    def test_extra_days_outside_the_window_are_ignored(self) -> None:
        extra = {"2026-09-26": 20.0, "2026-09-01": 999.0, "2026-09-28": 999.0}
        result = daily_exercise((), 80.0, _TODAY, extra)
        assert result["MET"] == pytest.approx(20.0 / 14)

    def test_short_history_average_uses_the_short_span(self) -> None:
        one_day = daily_exercise((), 80.0, _TODAY, {"2026-09-27": 90.0})
        assert one_day["MET"] == pytest.approx(90.0)


class TestWeekPlan:
    def test_week_starts_on_monday(self) -> None:
        assert week_start(date(2026, 10, 4)) == date(2026, 9, 28)

    def test_below_floor_only_with_remaining_days(self) -> None:
        low = plan_week(date(2026, 10, 1), 1500, {"2026-09-28": 5000}, {})
        assert low.below_floor
        full = plan_week(date(2026, 10, 4), 1500, {}, dict.fromkeys(range(7), 1500))
        assert not full.below_floor
