"""Tests for diet_guard._averages: period edges, bands, and coverage counts."""

from __future__ import annotations

from datetime import date, timedelta

from diet_guard import _averages_report
from diet_guard._averages import AverageBand
from diet_guard._budget_history import EPOCH_DAY, BudgetEntry, BudgetSchedule


def _entry(kcal: float) -> dict[str, object]:
    return {"kcal": kcal}


def _flat(budget: int) -> BudgetSchedule:
    """A schedule where one budget has applied since the beginning of time."""
    return BudgetSchedule(
        (BudgetEntry(EPOCH_DAY, budget, "1970-01-01T00:00:00+00:00"),),
        default=budget,
    )


def _days(start: str, kcals: list[float]) -> dict[str, list[dict[str, object]]]:
    """A log of consecutive days from ``start``, one entry each."""
    first = date.fromisoformat(start)
    return {
        (first + timedelta(days=offset)).isoformat(): [_entry(kcal)]
        for offset, kcal in enumerate(kcals)
    }


class TestWeeklyAverage:
    def test_current_week_stops_at_yesterday(self) -> None:
        # Today is Thursday 2026-01-08 and today's 100 kcal must NOT count:
        # the mean is over Mon-Wed only.
        log = _days("2026-01-05", [3000, 3000, 3000]) | {"2026-01-08": [_entry(100)]}
        result = _averages_report.weekly_average(
            log,
            schedule=_flat(2000),
            today=date(2026, 1, 8),
        )
        assert result.avg_kcal == 3000
        assert result.end == "2026-01-07"
        assert result.band is AverageBand.VERY_OVER

    def test_monday_has_no_complete_days_this_week(self) -> None:
        log = _days("2026-01-05", [3000])
        result = _averages_report.weekly_average(
            log,
            schedule=_flat(2000),
            today=date(2026, 1, 5),
        )
        assert result.elapsed_days == 0
        assert result.avg_kcal is None
        assert result.band is None

    def test_previous_week_is_whole(self) -> None:
        log = _days("2026-01-05", [2100, 2100, 2100, 2100, 2100, 2100, 2100])
        result = _averages_report.weekly_average(
            log,
            schedule=_flat(2000),
            weeks_ago=1,
            today=date(2026, 1, 14),
        )
        assert (result.start, result.end) == ("2026-01-05", "2026-01-11")
        assert result.elapsed_days == 7
        assert result.logged_days == 7
        assert result.band is AverageBand.SLIGHTLY_OVER

    def test_defaults_to_the_real_today(self) -> None:
        # No explicit `today`: the call must still resolve a real date range
        # rather than raising or returning an unbounded period.
        result = _averages_report.weekly_average({}, schedule=_flat(2000))
        assert result.elapsed_days >= 0


class TestMonthlyAverage:
    def test_current_month_stops_at_yesterday(self) -> None:
        log = _days("2026-03-01", [1000, 1000, 1000]) | {"2026-03-04": [_entry(9000)]}
        result = _averages_report.monthly_average(
            log,
            schedule=_flat(2000),
            today=date(2026, 3, 4),
        )
        assert result.avg_kcal == 1000
        assert (result.start, result.end) == ("2026-03-01", "2026-03-03")
        assert result.band is AverageBand.UNDER

    def test_first_of_the_month_has_no_complete_days(self) -> None:
        result = _averages_report.monthly_average(
            {},
            schedule=_flat(2000),
            today=date(2026, 3, 1),
        )
        assert result.elapsed_days == 0
        assert result.avg_kcal is None

    def test_previous_month_is_whole(self) -> None:
        log = _days("2026-02-01", [2500, 2500])
        result = _averages_report.monthly_average(
            log,
            schedule=_flat(2000),
            months_ago=1,
            today=date(2026, 3, 10),
        )
        assert (result.start, result.end) == ("2026-02-01", "2026-02-28")
        assert result.elapsed_days == 28
        assert result.logged_days == 2
        assert result.band is AverageBand.VERY_OVER

    def test_defaults_to_the_real_today(self) -> None:
        result = _averages_report.monthly_average({}, schedule=_flat(2000))
        assert result.elapsed_days >= 0


class TestRecentPeriods:
    def test_recent_weeks_are_newest_first(self) -> None:
        weeks = _averages_report.recent_weeks(
            {},
            schedule=_flat(2000),
            count=3,
            today=date(2026, 1, 14),
        )
        assert [week.start for week in weeks] == [
            "2026-01-12",
            "2026-01-05",
            "2025-12-29",
        ]

    def test_recent_months_are_newest_first(self) -> None:
        months = _averages_report.recent_months(
            {},
            schedule=_flat(2000),
            count=3,
            today=date(2026, 1, 14),
        )
        assert [month.start for month in months] == [
            "2026-01-01",
            "2025-12-01",
            "2025-11-01",
        ]

    def test_zero_count_is_empty(self) -> None:
        assert (
            _averages_report.recent_weeks(
                {},
                schedule=_flat(2000),
                count=0,
                today=date(2026, 1, 14),
            )
            == ()
        )

    def test_recent_weeks_defaults_to_the_real_today(self) -> None:
        assert (
            len(_averages_report.recent_weeks({}, schedule=_flat(2000), count=2)) == 2
        )

    def test_recent_months_defaults_to_the_real_today(self) -> None:
        assert (
            len(_averages_report.recent_months({}, schedule=_flat(2000), count=2)) == 2
        )
