"""CLI: ``body``, ``weight``, ``bodyfat``, ``profile`` and ``plan-week``.

State is redirected by conftest; ``_cli_body.publish_after_log`` is patched
there too, so no command here reaches the network.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from diet_guard import _cli_body
from diet_guard._body_fat_store import body_fats
from diet_guard._body_prefs import saved_goal
from diet_guard._body_store import set_profile, weights
from diet_guard._budget import read_raw_record, write_budget
from diet_guard._cli import main


def _run(capsys: pytest.CaptureFixture[str], *argv: str) -> tuple[int, str]:
    code = main(list(argv))
    return code, capsys.readouterr().out


def _profile() -> None:
    set_profile(birth="2000-05-22", height_cm=169.0, sex="m")


class TestBody:
    def test_incomplete_profile_comes_first(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        code, out = _run(capsys, "body")
        assert code == 0
        assert out.index("Profile:") < out.index("Set birth date")
        assert out.rstrip().endswith("Katch-McArdle).")

    def test_complete_profile_goes_last_before_body_fat(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        _profile()
        _run(capsys, "weight", "72.6")
        _run(capsys, "bodyfat", "16.8")
        _, out = _run(capsys, "body")
        assert out.startswith("To lose 0.5 kg / week on Moderate eat")
        assert out.index("Ideal range") < out.index("Profile:") < out.index("Body fat:")
        assert "Katch-McArdle resting burn" in out

    def test_overrides_and_save(self, capsys: pytest.CaptureFixture[str]) -> None:
        _profile()
        _run(capsys, "weight", "72.6")
        code, out = _run(
            capsys,
            "body",
            "--direction",
            "gain",
            "--amount",
            "1",
            "--weight-unit",
            "lb",
            "--time-unit",
            "month",
            "--activity",
            "sedentary",
            "--save",
        )
        assert code == 0
        assert out.startswith("goal saved.\nTo gain 1 lb / month on Sedentary eat")
        assert saved_goal().weight_unit == "lb"

    def test_maintain_and_measured_without_data(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        _profile()
        _run(capsys, "weight", "72.6")
        _, out = _run(capsys, "body", "--direction", "maintain")
        assert out.startswith("To maintain on Moderate eat")
        _, out = _run(capsys, "body", "--activity", "measured:MET")
        assert "no workouts published yet" in out.splitlines()[0]

    def test_far_below_the_floor_is_flagged(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        _profile()
        _run(capsys, "weight", "72.6")
        _, out = _run(capsys, "body", "--amount", "3", "--activity", "sedentary")
        assert "below the 1200 kcal floor" in out


class TestWeight:
    def test_log_list_and_reject(self, capsys: pytest.CaptureFixture[str]) -> None:
        assert _run(capsys, "weight", "500")[0] == 1
        _run(capsys, "weight", "80", "--date", "2026-09-01")
        _, out = _run(capsys, "weight")
        assert out == "2026-09-01  80.0 kg\n"

    def test_newest_day_moves_w_older_does_not(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        write_budget(2000, weight_kg=90.0)
        _run(capsys, "weight", "80", "--date", "2026-09-10")
        assert (read_raw_record() or {})["w"] == 80.0
        _run(capsys, "weight", "70", "--date", "2026-09-01")
        assert (read_raw_record() or {})["w"] == 80.0
        _run(capsys, "weight", "--delete", "--date", "2026-09-10")
        assert (read_raw_record() or {})["w"] == 70.0
        assert weights() == {"2026-09-01": 70.0}

    def test_bad_date_is_an_argparse_error(self) -> None:
        with pytest.raises(SystemExit):
            main(["weight", "80", "--date", "yesterday"])

    def test_publish_failure_is_reported(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        with patch.object(_cli_body, "publish_after_log", return_value="offline"):
            _, out = _run(capsys, "weight", "80")
        assert "not yet published (offline)" in out


class TestBodyFat:
    def test_log_list_reject_delete(self, capsys: pytest.CaptureFixture[str]) -> None:
        assert _run(capsys, "bodyfat", "90")[0] == 1
        _run(capsys, "bodyfat", "17.5", "--date", "2026-09-20")
        assert _run(capsys, "bodyfat")[1] == "2026-09-20  17.5%\n"
        _, out = _run(capsys, "bodyfat", "--delete", "--date", "2026-09-20")
        assert out.startswith("deleted for 2026-09-20.")
        assert body_fats() == {}


class TestProfile:
    def test_show_then_set(self, capsys: pytest.CaptureFixture[str]) -> None:
        assert _run(capsys, "profile")[1].startswith("Profile: birth date not set")
        _, out = _run(
            capsys, "profile", "--birth", "2000-05-22", "--height", "169", "--sex", "m"
        )
        assert out.startswith("profile saved.")
        assert "born 2000-05-22" in _run(capsys, "profile")[1]


class TestPlanWeek:
    def test_typed_days_and_default_target(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        code, out = _run(
            capsys, "plan-week", "--day", "mon=2500", "--day", "tuesday=1800"
        )
        assert code == 0
        assert "average of 2200 kcal/day" in out
        assert "2500  typed" in out
        write_budget(1900)
        assert "average of 1900" in _run(capsys, "plan-week")[1]

    def test_bad_day_spec(self) -> None:
        with pytest.raises(SystemExit):
            main(["plan-week", "--day", "funday=5"])
