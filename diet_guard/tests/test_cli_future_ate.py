"""Tests for ``diet_guard ate --date/--hour`` — pre-logging a future meal.

Split out of test_cli.py's ``TestAte`` for the repo's 250-line cap.
"""

from __future__ import annotations

from datetime import timedelta
from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _cli_log
from diet_guard._budget import write_budget
from diet_guard._cli import main
from diet_guard._estimator import Nutrition
from diet_guard._state import load_log, now_local

if TYPE_CHECKING:
    import pytest

_NUT = Nutrition(250, 12, 30, 10, 200, "manual")


class TestAteFutureDate:
    """Logging a meal against a future ``--date``/``--hour`` from the CLI."""

    def test_future_date_and_hour_logs_under_that_date(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """--date/--hour together pre-log against a future slot."""
        write_budget(2000)
        tomorrow = (now_local() + timedelta(days=1)).date().isoformat()
        with patch.object(_cli_log, "resolve_nutrition", return_value=_NUT):
            assert (
                main(["ate", "future lunch", "--date", tomorrow, "--hour", "12"]) == 0
            )
        out = capsys.readouterr().out
        assert "logged:" in out
        assert tomorrow in out
        assert load_log()[tomorrow][0]["slot"] == 12

    def test_date_without_hour_errors(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A lone --date without --hour is rejected before resolving food."""
        assert main(["ate", "x", "--date", "2099-01-01"]) == 1
        assert "must be given together" in capsys.readouterr().out

    def test_invalid_future_hour_errors(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """An hour that isn't a configured slot is rejected."""
        tomorrow = (now_local() + timedelta(days=1)).date().isoformat()
        assert main(["ate", "x", "--date", tomorrow, "--hour", "13"]) == 1
        assert "not a meal slot" in capsys.readouterr().out

    def test_past_date_errors(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A non-future date is rejected."""
        yesterday = (now_local() - timedelta(days=1)).date().isoformat()
        assert main(["ate", "x", "--date", yesterday, "--hour", "12"]) == 1
        assert "not a future date" in capsys.readouterr().out
