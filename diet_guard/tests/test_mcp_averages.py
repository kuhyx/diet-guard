"""Tests for the get_averages MCP tool, including its budget-secrecy invariant."""

from __future__ import annotations

from unittest.mock import patch

from diet_guard import _mcp
from diet_guard._averages import AverageBand, PeriodAverage
from diet_guard._budget import BudgetNotInitializedError


def _period(
    *,
    avg_kcal: float | None = 2100.0,
    band: AverageBand | None = AverageBand.SLIGHTLY_OVER,
) -> PeriodAverage:
    return PeriodAverage(
        start="2026-01-05",
        end="2026-01-11",
        logged_days=7,
        elapsed_days=7,
        avg_kcal=avg_kcal,
        avg_budget=2000.0,
        band=band,
    )


class TestPeriodView:
    def test_never_carries_the_average_budget(self) -> None:
        # The module invariant: no tool hands an automated caller the budget.
        view = _mcp._period_view(_period())
        assert "avg_budget" not in view
        assert 2000.0 not in view.values()

    def test_carries_intake_band_and_coverage(self) -> None:
        view = _mcp._period_view(_period())
        assert view["avg_kcal"] == 2100.0
        assert view["band"] == "slightly_over"
        assert view["band_label"] == "slightly over"
        assert view["logged_days"] == 7
        assert view["elapsed_days"] == 7
        assert view["start"] == "2026-01-05"
        assert view["end"] == "2026-01-11"

    def test_empty_period_serializes_as_null_not_zero(self) -> None:
        view = _mcp._period_view(_period(avg_kcal=None, band=None))
        assert view["avg_kcal"] is None
        assert view["band"] is None
        assert view["band_label"] == "no data"


class TestGetAverages:
    def test_returns_all_four_periods(self) -> None:
        with (
            patch.object(_mcp, "daily_budget", return_value=2000),
            patch.object(_mcp, "current_schedule"),
            patch.object(_mcp, "load_log", return_value={}),
            patch.object(_mcp, "weekly_average", return_value=_period()),
            patch.object(_mcp, "monthly_average", return_value=_period()),
        ):
            out = _mcp.get_averages()
        assert out["budget_initialized"] is True
        assert out["excludes_today"] is True
        assert set(out["periods"]) == {
            "this_week",
            "last_week",
            "this_month",
            "last_month",
        }

    def test_no_budget_degrades_to_empty_periods(self) -> None:
        with patch.object(
            _mcp,
            "daily_budget",
            side_effect=BudgetNotInitializedError,
        ):
            out = _mcp.get_averages()
        assert out == {"budget_initialized": False, "periods": {}}

    def test_no_response_field_leaks_the_budget_number(self) -> None:
        with (
            patch.object(_mcp, "daily_budget", return_value=2000),
            patch.object(_mcp, "current_schedule"),
            patch.object(_mcp, "load_log", return_value={}),
            patch.object(_mcp, "weekly_average", return_value=_period()),
            patch.object(_mcp, "monthly_average", return_value=_period()),
        ):
            out = _mcp.get_averages()
        flat = repr(out)
        assert "2000" not in flat
        assert "avg_budget" not in flat
