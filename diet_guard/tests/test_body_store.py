"""The Body document on disk: profile, weights, body fat, sessions, goal, steps.

``BODY_FILE`` is redirected into ``tmp_path`` by conftest's ``_isolate_state``.
"""

from __future__ import annotations

from datetime import date
import json

import pytest

from diet_guard import _body_store
from diet_guard._activity_kcal import Session
from diet_guard._body_activity_store import (
    activity,
    session_from_json,
    session_to_json,
    set_activity,
)
from diet_guard._body_energy import DEFAULT_GOAL, Goal
from diet_guard._body_fat_store import body_fats, newest_body_fat, set_body_fat
from diet_guard._body_prefs import goal_from_json, saved_goal, set_goal
from diet_guard._body_steps import daily_steps
from diet_guard._body_store import (
    Profile,
    WeightCandidate,
    age_on,
    apply_weight_candidates,
    newest_weight,
    profile,
    read_body,
    set_profile,
    set_weight,
    stamp_ms,
    weights,
    write_body,
)


def _raw(doc: object) -> None:
    _body_store.BODY_FILE.write_text(json.dumps(doc), encoding="utf-8")


def _cell(value: object) -> dict[str, object]:
    """Narrow a document cell (typed ``object``) for indexing."""
    assert isinstance(value, dict)
    return value


class TestReadBody:
    def test_missing_file_reads_as_empty_sections(self) -> None:
        assert read_body() == {s: {} for s in _body_store.SECTIONS}

    def test_corrupt_or_wrong_shape_reads_as_empty(self) -> None:
        _body_store.BODY_FILE.write_text("{not json", encoding="utf-8")
        assert read_body()["weights"] == {}
        _raw([1, 2])
        assert read_body()["profile"] == {}
        _raw({"weights": "nope"})
        assert read_body()["weights"] == {}

    def test_write_then_read_round_trips(self) -> None:
        doc = read_body()
        doc["weights"]["2026-09-01"] = {"kg": 80.0, "src": "manual", "t": "x"}
        write_body(doc)
        assert json.loads(_body_store.BODY_FILE.read_text())["v"] == 1
        assert _cell(read_body()["weights"]["2026-09-01"])["kg"] == 80.0


class TestHelpers:
    def test_age_counts_completed_years(self) -> None:
        assert age_on(date(2000, 5, 22), date(2026, 5, 21)) == 25
        assert age_on(date(2000, 5, 22), date(2026, 5, 22)) == 26

    def test_stamp_ms(self) -> None:
        assert stamp_ms("1970-01-01T00:00:01+00:00") == 1000
        assert stamp_ms("1970-01-01T00:00:02") == 2000  # naive = UTC
        assert stamp_ms("garbage") == 0
        assert stamp_ms(None) == 0


class TestProfile:
    def test_empty_profile_is_incomplete(self) -> None:
        prof = profile()
        assert not prof.complete
        assert prof.biometrics(80.0, date(2026, 9, 28)) is None

    def test_set_profile_and_biometrics(self) -> None:
        set_profile(birth="2000-05-22", height_cm=169.0, sex="m")
        prof = profile()
        assert prof.complete
        bio = prof.biometrics(72.6, date(2026, 9, 28))
        assert bio is not None
        assert bio.age_years == 26
        assert bio.is_male

    def test_malformed_fields_read_as_unset(self) -> None:
        _raw(
            {
                "profile": {
                    "birth": {"v": "not-a-date"},
                    "height_cm": {"v": True},
                    "sex": {"v": "x"},
                }
            }
        )
        assert profile() == Profile(birth=None, height_cm=None, sex=None)
        _raw({"profile": {"birth": {"v": 12}, "height_cm": {"v": -5}, "sex": "m"}})
        assert profile() == Profile(birth=None, height_cm=None, sex=None)


class TestWeights:
    def test_set_list_newest_and_delete(self) -> None:
        assert newest_weight() is None
        set_weight("2026-09-01", 80.123)
        set_weight("2026-09-10", 79.0)
        assert weights() == {"2026-09-01": 80.12, "2026-09-10": 79.0}
        set_weight("2026-09-10", None)
        assert newest_weight() == ("2026-09-01", 80.12)

    def test_bad_keys_and_values_are_skipped(self) -> None:
        _raw(
            {
                "weights": {
                    "garbage": {"kg": 70},
                    "2026-09-01": {"kg": "x"},
                    "2026-09-02": 5,
                }
            }
        )
        assert weights() == {}

    def test_candidates_apply_only_when_newer(self) -> None:
        set_weight("2026-09-27", 73.0)  # stamped now
        applied = apply_weight_candidates(
            [
                WeightCandidate(
                    "2026-09-27", 72.0, "phone", "2026-09-27T00:00:00+00:00"
                ),
                WeightCandidate(
                    "2026-09-26", 72.5, "phone", "2026-09-26T00:00:00+00:00"
                ),
            ]
        )
        assert applied == 1
        assert weights() == {"2026-09-26": 72.5, "2026-09-27": 73.0}
        assert apply_weight_candidates([]) == 0


class TestBodyFat:
    def test_log_newest_and_delete(self) -> None:
        assert newest_body_fat() is None
        set_body_fat("2026-09-20", 17.55)
        set_body_fat("2026-09-27", 16.8)
        assert body_fats() == {"2026-09-20": 17.6, "2026-09-27": 16.8}
        set_body_fat("2026-09-27", None)
        assert newest_body_fat() == 17.6

    def test_malformed_cells_are_skipped(self) -> None:
        _raw({"bodyfat": {"2026-09-01": 3, "bad": {"pct": 10}}})
        assert body_fats() == {}


class TestSessions:
    def test_round_trip_with_window(self) -> None:
        s = Session(
            "2026-09-23",
            "run",
            60.0,
            5.6,
            "Run",
            "runnerup",
            "2026-09-23T19:05:43+02:00",
            "2026-09-23T20:05:43+02:00",
        )
        assert session_from_json(session_to_json(s)) == s

    @pytest.mark.parametrize(
        "raw",
        [
            "x",
            {"day": 1, "kind": "run", "min": 5},
            {"day": "d", "kind": "run", "min": 0},
            {"day": "d", "kind": "run", "min": 5, "km": "far"},
        ],
    )
    def test_malformed_sessions_are_none(self, raw: object) -> None:
        assert session_from_json(raw) is None

    def test_bad_window_stamps_read_as_none(self) -> None:
        s = session_from_json(
            {"day": "d", "kind": "run", "min": 5, "start": 3, "end": "nope"}
        )
        assert s is not None
        assert s.start is None
        assert s.end is None

    def test_activity_publish_is_idempotent(self) -> None:
        assert activity() == ((), None)
        s = Session("2026-09-23", "strength", 80.0, None, "SL", "screen-locker")
        assert set_activity((s,)) is True
        assert set_activity((s,)) is False
        sessions, stamp = activity()
        assert sessions == (s,)
        assert stamp is not None

    def test_malformed_activity_reads_as_none(self) -> None:
        _raw({"activity": {"sessions": "x", "t": "2026"}})
        assert activity() == ((), None)


class TestGoalPrefs:
    def test_default_until_saved(self) -> None:
        assert saved_goal() == DEFAULT_GOAL
        goal = Goal("gain", 2.0, "lb", "month", "measured:ACSM")
        set_goal(goal)
        assert saved_goal() == goal

    def test_each_part_falls_back_on_its_own(self) -> None:
        assert goal_from_json("x") == DEFAULT_GOAL
        mixed = goal_from_json(
            {"dir": "sideways", "amt": -1, "wu": "stone?", "tu": "week", "act": "?"}
        )
        assert mixed == DEFAULT_GOAL
        assert goal_from_json({"amt": 3, "tu": "year"}).time_unit == "year"


class TestSteps:
    def test_daily_steps_reads_live_days(self) -> None:
        _raw({"steps": {"2026-09-27": {"n": 8421.0}, "bad": {"n": 5}, "2026-09-26": 4}})
        assert daily_steps() == {"2026-09-27": 8421}
