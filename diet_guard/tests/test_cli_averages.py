"""Tests for the averages subcommand's handler, split out of test_cli.py
alongside its source module (see _cli_averages.py's module docstring).
"""

from __future__ import annotations

from datetime import timedelta
from unittest.mock import patch

from diet_guard import _cli, _cli_averages
from diet_guard._averages import AverageBand, PeriodAverage
from diet_guard._budget import (
    BudgetFileCorruptError,
    BudgetNotInitializedError,
    write_budget,
)
from diet_guard._state import now_local


def _period(
    *,
    avg_kcal: float | None = 2100.0,
    avg_budget: float | None = 2000.0,
    band: AverageBand | None = AverageBand.SLIGHTLY_OVER,
    logged_days: int = 7,
) -> PeriodAverage:
    """A fully-populated period, overridable field by field."""
    return PeriodAverage(
        start="2026-01-05",
        end="2026-01-11",
        logged_days=logged_days,
        elapsed_days=7,
        avg_kcal=avg_kcal,
        avg_budget=avg_budget,
        band=band,
    )


class TestFormatPeriod:
    def test_renders_average_band_budget_and_coverage(self) -> None:
        line = _cli_averages._format_period("this week", _period())
        assert "2026-01-05..2026-01-11" in line
        assert "2100 kcal/day" in line
        assert "slightly over" in line
        assert "budget 2000" in line
        assert "[7/7 days logged]" in line

    def test_rounds_the_average_to_whole_kcal(self) -> None:
        line = _cli_averages._format_period("this week", _period(avg_kcal=2100.6))
        assert "2101 kcal/day" in line

    def test_empty_period_says_so_instead_of_printing_zero(self) -> None:
        line = _cli_averages._format_period(
            "this week",
            _period(avg_kcal=None, avg_budget=None, band=None, logged_days=0),
        )
        assert line.endswith("no logged days yet")
        assert "kcal/day" not in line

    def test_missing_budget_alone_also_degrades(self) -> None:
        # avg_budget is None only when avg_kcal is too, but the guard covers
        # both so a future partial period can never format "budget None".
        line = _cli_averages._format_period("this week", _period(avg_budget=None))
        assert line.endswith("no logged days yet")

    def test_label_column_is_padded_so_the_dates_line_up(self) -> None:
        short = _cli_averages._format_period("this week", _period())
        long = _cli_averages._format_period("this month", _period())
        assert short.index("2026-01-05") == long.index("2026-01-05")


class TestCmdAverages:
    def test_prints_a_header_and_one_line_per_period(self) -> None:
        write_budget(2000)
        lines: list[str] = []
        assert _cli_averages.cmd_averages(lines.append) == 0
        assert lines[0] == "averages exclude today, which is still being logged."
        assert len(lines) == 5
        assert [" ".join(line.split()[:2]) for line in lines[1:]] == [
            "this week",
            "last week",
            "this month",
            "last month",
        ]

    def test_a_logged_past_day_reaches_the_average(self) -> None:
        write_budget(2000)
        yesterday = (now_local().date() - timedelta(days=1)).isoformat()
        log = {yesterday: [{"kcal": 2500.0}]}
        lines: list[str] = []
        with patch.object(_cli_averages, "load_log", return_value=log):
            assert _cli_averages.cmd_averages(lines.append) == 0
        assert any("2500 kcal/day" in line for line in lines)
        assert any("very over" in line for line in lines)

    def test_today_is_excluded_from_the_average(self) -> None:
        # Today's 9000 kcal must not appear anywhere: every period stops at
        # yesterday, so a half-logged day cannot flip a band.
        write_budget(2000)
        today = now_local().date().isoformat()
        lines: list[str] = []
        with patch.object(
            _cli_averages,
            "load_log",
            return_value={today: [{"kcal": 9000.0}]},
        ):
            assert _cli_averages.cmd_averages(lines.append) == 0
        assert not any("9000 kcal/day" in line for line in lines)

    def test_uninitialized_budget_is_reported_not_crashed(self) -> None:
        lines: list[str] = []
        with patch.object(
            _cli_averages,
            "daily_budget",
            side_effect=BudgetNotInitializedError,
        ):
            assert _cli_averages.cmd_averages(lines.append) == 1
        assert lines == ["budget not set - run: python -m diet_guard init"]

    def test_corrupt_budget_is_reported_not_crashed(self) -> None:
        lines: list[str] = []
        with patch.object(
            _cli_averages,
            "daily_budget",
            side_effect=BudgetFileCorruptError,
        ):
            assert _cli_averages.cmd_averages(lines.append) == 1
        assert lines == ["budget file corrupt - re-run init"]


class TestSubparser:
    def test_averages_is_reachable_from_main(self) -> None:
        with patch.object(_cli, "cmd_averages", return_value=0) as handler:
            assert _cli.main(["averages"]) == 0
        assert handler.call_count == 1
