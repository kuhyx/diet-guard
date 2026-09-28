"""The text renderer and the view it renders, over seeded Body state."""

from __future__ import annotations

from dataclasses import replace
from datetime import date
import json
from unittest.mock import patch

from diet_guard import _sync_body
from diet_guard._activity_kcal import Session, window_days
from diet_guard._body_activity_store import set_activity
from diet_guard._body_ingest import weight_candidates
from diet_guard._body_prefs import goal_from_json
from diet_guard._body_report import (
    activity_lines,
    bodyfat_lines,
    ideal_lines,
    plan_lines,
    target_lines,
)
from diet_guard._body_store import read_body, set_profile, set_weight, write_body
from diet_guard._body_view import build_view
from diet_guard._week_plan import plan_week

_TODAY = date(2026, 9, 28)


def _person() -> None:
    set_profile(birth="2000-05-22", height_cm=169.0, sex="m")
    set_weight("2026-09-27", 72.6)


class TestView:
    def test_empty_view(self) -> None:
        view = build_view(_TODAY)
        assert view.weight is None
        assert view.numbers is None
        assert view.exercise is None
        assert activity_lines(view) == [
            "No workouts published yet (the PC publishes them on sync)."
        ]
        assert target_lines(view)[0].startswith("Set birth date")
        assert ideal_lines(view)[0].startswith("Set birth date")

    def test_published_workouts_and_steps(self) -> None:
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
        view = build_view(_TODAY)
        assert view.weight == 72.6
        assert view.exercise is not None
        assert view.exercise.days == 6
        lines = activity_lines(view)
        assert lines[1].startswith("Last 6 full days, net exercise kcal/day: MET")
        assert lines[2].startswith("Steps outside workouts: 9000 on 2026-09-26")
        assert any(" run " in line and "6.0 km  M" in line for line in lines)

    def test_steps_alone_show_without_a_publish_stamp(self) -> None:
        _person()
        doc = read_body()
        doc["steps"] = {"2026-09-27": {"n": 3000, "t": "2026-09-27T22:00:00+02:00"}}
        write_body(doc)
        view = build_view(_TODAY)
        assert activity_lines(view)[0] == "Workouts published not yet"

    def test_sessions_without_a_weight_have_no_kcal(self) -> None:
        set_activity((Session("2026-09-22", "run", 60.0, None, "Run", "runnerup"),))
        line = activity_lines(build_view(_TODAY))[1]
        assert line.endswith("min")


class TestTargetAndIdeal:
    def test_missing_summary_skips_average_rows(self) -> None:
        _person()
        view = build_view(_TODAY)
        assert view.numbers is not None
        bare = replace(view, numbers=replace(view.numbers, ideal_summary=None))
        assert not any("Average of all" in line for line in ideal_lines(bare))

    def test_body_fat_lines(self) -> None:
        assert bodyfat_lines(build_view(_TODAY))[0].startswith("Body fat: not logged")


class TestPlanLines:
    def test_all_known_and_unlogged_and_floor(self) -> None:
        full = plan_week(date(2026, 10, 4), 1800, {}, dict.fromkeys(range(7), 1900))
        assert plan_lines(full)[-1].startswith("Every day is known")
        low = plan_week(date(2026, 10, 1), 1500, {"2026-09-28": 5000}, {})
        lines = plan_lines(low)
        assert "(no log - type it?)" in lines[2]
        assert lines[-1].endswith("floor!")


class TestLeftoverBranches:
    def test_future_extra_days_are_ignored(self) -> None:
        assert window_days((), _TODAY, {"2026-09-28": 5.0}) == 0

    def test_an_older_candidate_does_not_replace_a_newer_one(self) -> None:
        newer = json.dumps(
            {
                "alarm": {
                    "fields": {
                        "morning_sessions": [
                            [{"date": "2026-09-27", "weight_kg": 71}],
                            "x",
                        ]
                    }
                }
            }
        )
        older_hlc = "1970-01-01T00:00:00.000Z-0000-a"
        older = (
            '{"alarm": {"fields": {"latest_weight_kg": '
            f'[{{"date": "2026-09-27", "kg": 70}}, "{older_hlc}"]}}}}}}'
        )
        cands = weight_candidates([("n", newer), ("o", older)])
        assert [c.kg for c in cands] == [71.0]

    def test_unknown_time_unit_keeps_the_default(self) -> None:
        assert goal_from_json({"tu": "fortnight"}).time_unit == "week"

    def test_unchanged_activity_is_not_republished(self) -> None:
        with (
            patch.object(_sync_body, "sources_available", return_value=True),
            patch.object(_sync_body, "collect_sessions", return_value=()),
            patch.object(_sync_body, "set_activity", return_value=False),
            patch.object(_sync_body._logger, "info") as info,
        ):
            _sync_body.publish_activity()
        info.assert_not_called()
