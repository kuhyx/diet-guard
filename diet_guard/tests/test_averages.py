"""Tests for diet_guard._averages: period edges, bands, and coverage counts."""

from __future__ import annotations

from datetime import date, timedelta

from diet_guard import _averages
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


class TestBandFor:
    def test_exactly_at_budget_is_under(self) -> None:
        assert _averages.band_for(2000, 2000) is AverageBand.UNDER

    def test_below_budget_is_under(self) -> None:
        assert _averages.band_for(1500, 2000) is AverageBand.UNDER

    def test_one_over_is_slightly_over(self) -> None:
        assert _averages.band_for(2001, 2000) is AverageBand.SLIGHTLY_OVER

    def test_exactly_at_ceiling_is_slightly_over(self) -> None:
        # 2400 sits right at the 120% ceiling for a 2000 budget.
        assert _averages.band_for(2400, 2000) is AverageBand.SLIGHTLY_OVER

    def test_just_past_ceiling_is_very_over(self) -> None:
        assert _averages.band_for(2400.01, 2000) is AverageBand.VERY_OVER

    def test_way_past_ceiling_is_very_over(self) -> None:
        assert _averages.band_for(4000, 2000) is AverageBand.VERY_OVER

    def test_boundary_matches_the_calendar_day_boundary(self) -> None:
        # The averages line and the calendar must never disagree about "over":
        # a period averaging exactly one day's YELLOW total is SLIGHTLY_OVER.
        ceiling = _averages.OVER_BUDGET_YELLOW_CEILING
        assert _averages.band_for(2000 * ceiling, 2000) is AverageBand.SLIGHTLY_OVER


class TestBandLabel:
    def test_none_is_no_data(self) -> None:
        assert _averages.band_label(None) == "no data"

    def test_under(self) -> None:
        assert _averages.band_label(AverageBand.UNDER) == "under"

    def test_slightly_over(self) -> None:
        assert _averages.band_label(AverageBand.SLIGHTLY_OVER) == "slightly over"

    def test_very_over(self) -> None:
        assert _averages.band_label(AverageBand.VERY_OVER) == "very over"


class TestPeriodBounds:
    def test_week_starts_monday(self) -> None:
        # 2026-01-07 is a Wednesday.
        start, end = _averages.week_bounds(date(2026, 1, 7))
        assert (start, end) == (date(2026, 1, 5), date(2026, 1, 11))

    def test_week_of_a_monday_is_that_monday(self) -> None:
        start, end = _averages.week_bounds(date(2026, 1, 5))
        assert (start, end) == (date(2026, 1, 5), date(2026, 1, 11))

    def test_week_of_a_sunday_looks_back(self) -> None:
        start, end = _averages.week_bounds(date(2026, 1, 11))
        assert (start, end) == (date(2026, 1, 5), date(2026, 1, 11))

    def test_month_bounds(self) -> None:
        start, end = _averages.month_bounds(date(2026, 2, 14))
        assert (start, end) == (date(2026, 2, 1), date(2026, 2, 28))

    def test_month_bounds_leap_february(self) -> None:
        _, end = _averages.month_bounds(date(2024, 2, 14))
        assert end == date(2024, 2, 29)

    def test_last_complete_day_is_yesterday(self) -> None:
        assert _averages.last_complete_day(date(2026, 3, 1)) == date(2026, 2, 28)


class TestShiftMonths:
    def test_zero_is_the_same_month(self) -> None:
        assert _averages._shift_months(date(2026, 5, 20), 0) == date(2026, 5, 1)

    def test_one_back(self) -> None:
        assert _averages._shift_months(date(2026, 5, 20), 1) == date(2026, 4, 1)

    def test_wraps_the_year(self) -> None:
        assert _averages._shift_months(date(2026, 1, 20), 1) == date(2025, 12, 1)

    def test_wraps_several_years(self) -> None:
        assert _averages._shift_months(date(2026, 3, 20), 27) == date(2023, 12, 1)


class TestPeriodAverage:
    def test_averages_over_logged_days_only(self) -> None:
        # Three logged days (2000, 3000, 4000) plus two gaps: the mean is
        # 3000, NOT 1800 -- a day you forgot to log is not a zero-kcal day.
        log = {
            "2026-01-05": [_entry(2000)],
            "2026-01-06": [_entry(3000)],
            "2026-01-09": [_entry(4000)],
        }
        result = _averages.period_average(
            log,
            schedule=_flat(2500),
            start=date(2026, 1, 5),
            end=date(2026, 1, 9),
        )
        assert result.avg_kcal == 3000
        assert result.logged_days == 3
        assert result.elapsed_days == 5

    def test_sums_multiple_entries_in_a_day(self) -> None:
        log = {"2026-01-05": [_entry(1200), _entry(800)]}
        result = _averages.period_average(
            log,
            schedule=_flat(2000),
            start=date(2026, 1, 5),
            end=date(2026, 1, 5),
        )
        assert result.avg_kcal == 2000
        assert result.band is AverageBand.UNDER

    def test_empty_period_has_no_average(self) -> None:
        result = _averages.period_average(
            {},
            schedule=_flat(2000),
            start=date(2026, 1, 5),
            end=date(2026, 1, 11),
        )
        assert result.avg_kcal is None
        assert result.avg_budget is None
        assert result.band is None
        assert result.logged_days == 0
        assert result.elapsed_days == 7

    def test_end_before_start_is_zero_elapsed_not_negative(self) -> None:
        result = _averages.period_average(
            {},
            schedule=_flat(2000),
            start=date(2026, 1, 5),
            end=date(2026, 1, 4),
        )
        assert result.elapsed_days == 0
        assert result.avg_kcal is None

    def test_days_outside_the_range_are_ignored(self) -> None:
        log = {"2026-01-04": [_entry(9000)], "2026-01-05": [_entry(1000)]}
        result = _averages.period_average(
            log,
            schedule=_flat(2000),
            start=date(2026, 1, 5),
            end=date(2026, 1, 5),
        )
        assert result.avg_kcal == 1000

    def test_budget_is_averaged_per_logged_day_not_taken_from_today(self) -> None:
        # The budget rose to 3000 partway through: a period spanning the change
        # is judged against the mean of the two, not against either endpoint.
        schedule = BudgetSchedule(
            (
                BudgetEntry(EPOCH_DAY, 1000, "1970-01-01T00:00:00+00:00"),
                BudgetEntry("2026-01-06", 3000, "2026-01-06T00:00:00+00:00"),
            ),
            default=1000,
        )
        log = {"2026-01-05": [_entry(2000)], "2026-01-06": [_entry(2000)]}
        result = _averages.period_average(
            log,
            schedule=schedule,
            start=date(2026, 1, 5),
            end=date(2026, 1, 6),
        )
        assert result.avg_budget == 2000
        assert result.band is AverageBand.UNDER

    def test_unlogged_days_do_not_pull_the_budget_average(self) -> None:
        # Only the logged day counts on both sides of the comparison.
        schedule = BudgetSchedule(
            (
                BudgetEntry(EPOCH_DAY, 1000, "1970-01-01T00:00:00+00:00"),
                BudgetEntry("2026-01-06", 3000, "2026-01-06T00:00:00+00:00"),
            ),
            default=1000,
        )
        log = {"2026-01-06": [_entry(2000)]}
        result = _averages.period_average(
            log,
            schedule=schedule,
            start=date(2026, 1, 5),
            end=date(2026, 1, 6),
        )
        assert result.avg_budget == 3000

    def test_reports_its_own_range(self) -> None:
        result = _averages.period_average(
            {},
            schedule=_flat(2000),
            start=date(2026, 1, 5),
            end=date(2026, 1, 11),
        )
        assert (result.start, result.end) == ("2026-01-05", "2026-01-11")


class TestWeeklyAverage:
    def test_current_week_stops_at_yesterday(self) -> None:
        # Today is Thursday 2026-01-08 and today's 100 kcal must NOT count:
        # the mean is over Mon-Wed only.
        log = _days("2026-01-05", [3000, 3000, 3000]) | {"2026-01-08": [_entry(100)]}
        result = _averages.weekly_average(
            log,
            schedule=_flat(2000),
            today=date(2026, 1, 8),
        )
        assert result.avg_kcal == 3000
        assert result.end == "2026-01-07"
        assert result.band is AverageBand.VERY_OVER

    def test_monday_has_no_complete_days_this_week(self) -> None:
        log = _days("2026-01-05", [3000])
        result = _averages.weekly_average(
            log,
            schedule=_flat(2000),
            today=date(2026, 1, 5),
        )
        assert result.elapsed_days == 0
        assert result.avg_kcal is None
        assert result.band is None

    def test_previous_week_is_whole(self) -> None:
        log = _days("2026-01-05", [2100, 2100, 2100, 2100, 2100, 2100, 2100])
        result = _averages.weekly_average(
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
        result = _averages.weekly_average({}, schedule=_flat(2000))
        assert result.elapsed_days >= 0


class TestMonthlyAverage:
    def test_current_month_stops_at_yesterday(self) -> None:
        log = _days("2026-03-01", [1000, 1000, 1000]) | {"2026-03-04": [_entry(9000)]}
        result = _averages.monthly_average(
            log,
            schedule=_flat(2000),
            today=date(2026, 3, 4),
        )
        assert result.avg_kcal == 1000
        assert (result.start, result.end) == ("2026-03-01", "2026-03-03")
        assert result.band is AverageBand.UNDER

    def test_first_of_the_month_has_no_complete_days(self) -> None:
        result = _averages.monthly_average(
            {},
            schedule=_flat(2000),
            today=date(2026, 3, 1),
        )
        assert result.elapsed_days == 0
        assert result.avg_kcal is None

    def test_previous_month_is_whole(self) -> None:
        log = _days("2026-02-01", [2500, 2500])
        result = _averages.monthly_average(
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
        result = _averages.monthly_average({}, schedule=_flat(2000))
        assert result.elapsed_days >= 0


class TestRecentPeriods:
    def test_recent_weeks_are_newest_first(self) -> None:
        weeks = _averages.recent_weeks(
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
        months = _averages.recent_months(
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
            _averages.recent_weeks(
                {},
                schedule=_flat(2000),
                count=0,
                today=date(2026, 1, 14),
            )
            == ()
        )

    def test_recent_weeks_defaults_to_the_real_today(self) -> None:
        assert len(_averages.recent_weeks({}, schedule=_flat(2000), count=2)) == 2

    def test_recent_months_defaults_to_the_real_today(self) -> None:
        assert len(_averages.recent_months({}, schedule=_flat(2000), count=2)) == 2
