"""The gate's glyph twins of the Body report blocks, and the glyph table."""

from __future__ import annotations

from dataclasses import replace
from datetime import date

import pytest

from diet_guard import _gatelock_glyphs as g
from diet_guard._activity_kcal import Session
from diet_guard._body_activity_store import set_activity
from diet_guard._body_fat_store import set_body_fat
from diet_guard._body_prefs import goal_from_json
from diet_guard._body_store import read_body, set_profile, set_weight, write_body
from diet_guard._body_view import build_view
from diet_guard._gatelock_body_glyphs import (
    ACTIVITY,
    _band,
    activity_glyphs,
    bmi_glyphs,
    bmr_glyphs,
    bodyfat_glyphs,
    ideal_glyphs,
    plan_glyphs,
    profile_glyphs,
    target_glyphs,
)
from diet_guard._week_plan import plan_week

_TODAY = date(2026, 9, 28)


def _person() -> None:
    set_profile(birth="2000-05-22", height_cm=169.0, sex="m")
    set_weight("2026-09-27", 72.6)


class TestEmptyState:
    def test_every_block_has_a_placeholder_not_a_sentence(self) -> None:
        view = build_view(_TODAY)
        assert profile_glyphs(view, _TODAY) == [
            f"{g.BIRTH} {g.NO_VALUE}   {g.NO_VALUE} cm   {g.NO_VALUE}",
            f"{g.AMOUNT} {g.NO_VALUE} kg",
        ]
        assert bodyfat_glyphs(view) == [f"% {g.NO_VALUE}"]
        assert bmi_glyphs(view) == [f"{g.TAB_BODY} ?"]
        assert ideal_glyphs(view) == [f"{g.IDEAL} ?"]
        assert bmr_glyphs(view) == [f"{g.RESTING} ?"]
        assert target_glyphs(view) == ["?"]
        assert activity_glyphs(view) == [f"{g.MEASURED} {g.EMPTY}"]


class TestWithData:
    def test_profile_bmi_ideal_and_bmr(self) -> None:
        _person()
        set_body_fat("2026-09-27", 18.5)
        view = build_view(_TODAY)
        assert profile_glyphs(view, _TODAY)[0].startswith(f"{g.BIRTH} 2000-05-22 (26)")
        assert profile_glyphs(view, _TODAY)[1].startswith(f"{g.AMOUNT} 72.6 kg")
        assert bodyfat_glyphs(view)[0].startswith("18.5%")
        assert bmi_glyphs(view)[0].startswith(f"{g.TAB_BODY} 25.4 △")
        assert ideal_glyphs(view)[0].startswith(f"{g.IDEAL} ")
        assert bmr_glyphs(view)[0].startswith(f"{g.RESTING} ")

    def test_target_and_the_floor_warning(self) -> None:
        _person()
        view = build_view(_TODAY)
        assert view.numbers is not None
        assert target_glyphs(view)[0].startswith("= ")
        low = replace(
            view,
            numbers=replace(
                view.numbers,
                target=replace(view.numbers.target, kcal=900),
            ),
        )
        assert target_glyphs(low)[-1].startswith(g.WARN)

    def test_an_unanswered_measured_goal_shows_the_empty_mark(self) -> None:
        _person()
        goal = goal_from_json({"act": "measured:MET"})
        view = build_view(_TODAY, goal)
        assert target_glyphs(view) == [f"{g.MEASURED} {g.EMPTY}"]

    def test_activity_means_steps_and_sessions(self) -> None:
        _person()
        set_activity(
            (
                Session("2026-09-22", "run", 60.0, 6.0, "Run", "runnerup"),
                Session("2026-09-25", "strength", 80.0, None, "SL", "screen-locker"),
            )
        )
        doc = read_body()
        doc["steps"] = {"2026-09-26": {"n": 9000, "t": "2026-09-26T22:00:00+02:00"}}
        write_body(doc)
        lines = activity_glyphs(build_view(_TODAY))
        assert lines[0].startswith(g.SYNC)
        assert lines[1].startswith(f"{g.AVERAGE} 6")
        assert lines[2].startswith(f"{g.STEPS} 9000")
        assert any(" run " in line and "6.0 km" in line for line in lines)
        assert any("MET" in line and "↗" in line and "/km" in line for line in lines)

    def test_sessions_without_a_weight_carry_no_kcal(self) -> None:
        set_activity((Session("2026-09-22", "run", 60.0, None, "Run", "runnerup"),))
        assert activity_glyphs(build_view(_TODAY))[1].endswith("min")

    def test_steps_alone_have_a_dash_for_the_stamp(self) -> None:
        _person()
        doc = read_body()
        doc["steps"] = {"2026-09-27": {"n": 3000, "t": "2026-09-27T22:00:00+02:00"}}
        write_body(doc)
        assert activity_glyphs(build_view(_TODAY))[0] == f"{g.SYNC} {g.NO_VALUE}"


class TestBand:
    @pytest.mark.parametrize(
        ("category", "glyph"),
        [
            ("severe thinness", "▽"),
            ("normal", g.OK),
            ("overweight", "△"),
            ("obese class II", "▲"),
            ("adult categories do not apply under 20", g.NO_VALUE),
        ],
    )
    def test_each_who_band_has_its_own_shape(self, category: str, glyph: str) -> None:
        assert _band(category) == glyph


class TestPlan:
    def test_sources_and_the_remaining_line(self) -> None:
        low = plan_week(date(2026, 10, 1), 1500, {"2026-09-28": 5000}, {})
        lines = plan_glyphs(low)
        assert lines[0] == f"{g.AVERAGE} 1500 kcal"
        assert g.EDIT not in lines[1]
        assert "?" in lines[2]
        assert lines[-1].endswith(g.WARN)

    def test_a_fully_known_week_reports_its_average(self) -> None:
        full = plan_week(date(2026, 10, 4), 1800, {}, dict.fromkeys(range(7), 1900))
        assert plan_glyphs(full)[-1] == f"{g.OK} {g.AVERAGE} 1900 kcal"

    def test_the_remaining_line_without_a_warning(self) -> None:
        plan = plan_week(date(2026, 10, 1), 2200, {}, {})
        assert plan_glyphs(plan)[-1].startswith("→")
        assert g.WARN not in plan_glyphs(plan)[-1]


class TestGlyphTable:
    def test_activity_picker_covers_every_choice(self) -> None:
        assert ACTIVITY["sedentary"] == "▁"
        assert ACTIVITY["measured:ACSM"] == f"{g.MEASURED} ↗"

    @pytest.mark.parametrize(
        ("source", "glyph"),
        [
            ("food bank", "▤"),
            ("staple: apple", "★"),
            ("catering", g.DELIVERY),
            ("manual", g.FOOD),
            ("openfoodfacts", "≈"),
        ],
    )
    def test_every_nutrition_source_has_a_glyph(self, source: str, glyph: str) -> None:
        assert g.source_glyph(source) == glyph
