"""Tests for diet_guard._daystatus: status classification, streaks, tallies."""

from __future__ import annotations

from datetime import date

from diet_guard import _budget, _daystatus, _state
from diet_guard._daystatus import DayStatus
from diet_guard._estimator import Nutrition


def _entry(kcal: float) -> dict[str, object]:
    return {"kcal": kcal}


class TestDayTotalKcal:
    def test_sums_entries(self) -> None:
        log = {"2026-01-01": [_entry(100), _entry(50)]}
        assert _daystatus.day_total_kcal(log, "2026-01-01") == 150

    def test_missing_day_is_zero(self) -> None:
        assert _daystatus.day_total_kcal({}, "2026-01-01") == 0


class TestDayStatus:
    def test_missing_day_is_not_logged(self) -> None:
        assert _daystatus.day_status({}, "2026-01-01", 2000) == DayStatus.NOT_LOGGED

    def test_exactly_at_budget_is_green(self) -> None:
        log = {"2026-01-01": [_entry(2000)]}
        assert _daystatus.day_status(log, "2026-01-01", 2000) == DayStatus.GREEN

    def test_under_budget_is_green(self) -> None:
        log = {"2026-01-01": [_entry(1000)]}
        assert _daystatus.day_status(log, "2026-01-01", 2000) == DayStatus.GREEN

    def test_just_over_budget_is_yellow(self) -> None:
        log = {"2026-01-01": [_entry(2001)]}
        assert _daystatus.day_status(log, "2026-01-01", 2000) == DayStatus.YELLOW

    def test_exactly_at_yellow_ceiling_is_yellow(self) -> None:
        # 2400 sits right at the yellow ceiling for a 2000 budget (120%).
        log = {"2026-01-01": [_entry(2400)]}
        assert _daystatus.day_status(log, "2026-01-01", 2000) == DayStatus.YELLOW

    def test_just_over_yellow_ceiling_is_red(self) -> None:
        log = {"2026-01-01": [_entry(2400.01)]}
        assert _daystatus.day_status(log, "2026-01-01", 2000) == DayStatus.RED

    def test_way_over_budget_is_red(self) -> None:
        log = {"2026-01-01": [_entry(5000)]}
        assert _daystatus.day_status(log, "2026-01-01", 2000) == DayStatus.RED

    def test_day_with_only_tombstoned_entries_is_not_logged(self) -> None:
        # A tombstoned entry is kept on disk but load_log() drops it, so the
        # day is entirely absent from the filtered log rather than present
        # with an empty list -- confirm that reads as NOT_LOGGED, not GREEN.
        _state.log_meal("snack", Nutrition(300, 5, 40, 10, 100, "manual"))
        _state.undo_last_today()
        today = _state._today()
        assert today not in _state.load_log()
        assert (
            _daystatus.day_status(_state.load_log(), today, 2000)
            == DayStatus.NOT_LOGGED
        )


class TestStatusMap:
    def test_maps_every_present_day(self) -> None:
        log = {
            "2026-01-01": [_entry(1000)],
            "2026-01-02": [_entry(5000)],
        }
        result = _daystatus.status_map(log, budget=2000)
        assert result == {
            "2026-01-01": DayStatus.GREEN,
            "2026-01-02": DayStatus.RED,
        }

    def test_empty_log_is_empty_map(self) -> None:
        assert _daystatus.status_map({}, budget=2000) == {}


class TestLoggingStreak:
    def test_empty_map_is_zero(self) -> None:
        assert _daystatus.logging_streak({}, today=date(2026, 1, 5)) == 0

    def test_counts_consecutive_logged_days_including_today(self) -> None:
        sm = {
            "2026-01-03": DayStatus.GREEN,
            "2026-01-04": DayStatus.RED,
            "2026-01-05": DayStatus.YELLOW,
        }
        assert _daystatus.logging_streak(sm, today=date(2026, 1, 5)) == 3

    def test_breaks_on_gap(self) -> None:
        sm = {
            "2026-01-01": DayStatus.GREEN,
            "2026-01-03": DayStatus.GREEN,
            "2026-01-04": DayStatus.GREEN,
        }
        assert _daystatus.logging_streak(sm, today=date(2026, 1, 4)) == 2

    def test_today_not_logged_is_not_a_break(self) -> None:
        sm = {
            "2026-01-03": DayStatus.GREEN,
            "2026-01-04": DayStatus.YELLOW,
        }
        # today (01-05) has no entry yet -- should not zero out the streak.
        assert _daystatus.logging_streak(sm, today=date(2026, 1, 5)) == 2

    def test_yesterday_not_logged_breaks_streak_even_if_today_is(self) -> None:
        sm = {
            "2026-01-03": DayStatus.GREEN,
            "2026-01-05": DayStatus.GREEN,
        }
        assert _daystatus.logging_streak(sm, today=date(2026, 1, 5)) == 1


class TestAdherenceStreak:
    def test_counts_consecutive_green_and_yellow(self) -> None:
        sm = {
            "2026-01-03": DayStatus.GREEN,
            "2026-01-04": DayStatus.YELLOW,
            "2026-01-05": DayStatus.GREEN,
        }
        assert _daystatus.adherence_streak(sm, today=date(2026, 1, 5)) == 3

    def test_red_today_breaks_streak_immediately(self) -> None:
        sm = {
            "2026-01-04": DayStatus.GREEN,
            "2026-01-05": DayStatus.RED,
        }
        assert _daystatus.adherence_streak(sm, today=date(2026, 1, 5)) == 0

    def test_not_logged_today_is_not_a_break(self) -> None:
        sm = {"2026-01-04": DayStatus.GREEN}
        assert _daystatus.adherence_streak(sm, today=date(2026, 1, 5)) == 1

    def test_red_in_history_breaks_streak(self) -> None:
        sm = {
            "2026-01-03": DayStatus.GREEN,
            "2026-01-04": DayStatus.RED,
            "2026-01-05": DayStatus.GREEN,
        }
        assert _daystatus.adherence_streak(sm, today=date(2026, 1, 5)) == 1


class TestYearToDateTally:
    def test_counts_logged_and_adherent_days_this_year_only(self) -> None:
        sm = {
            "2026-01-01": DayStatus.GREEN,
            "2026-01-02": DayStatus.RED,
            "2026-01-03": DayStatus.NOT_LOGGED,
            "2025-12-31": DayStatus.GREEN,  # previous year, excluded
        }
        tally = _daystatus.year_to_date_tally(sm, today=date(2026, 1, 3))
        assert tally.logged_days == 2
        assert tally.elapsed_days == 3
        assert tally.adherent_days == 1

    def test_future_day_in_map_excluded(self) -> None:
        sm = {
            "2026-01-01": DayStatus.GREEN,
            "2026-06-01": DayStatus.GREEN,
        }
        tally = _daystatus.year_to_date_tally(sm, today=date(2026, 1, 1))
        assert tally.logged_days == 1
        assert tally.elapsed_days == 1
        assert tally.adherent_days == 1

    def test_empty_map(self) -> None:
        tally = _daystatus.year_to_date_tally({}, today=date(2026, 3, 1))
        assert tally.logged_days == 0
        assert tally.elapsed_days == 60
        assert tally.adherent_days == 0


class TestCurrentStatusMap:
    def test_reads_real_log_and_budget(self) -> None:
        _budget.write_budget(2000)
        _state.log_meal("lunch", Nutrition(500, 30, 40, 10, 100, "manual"))
        result = _daystatus.current_status_map()
        assert len(result) == 1
        assert next(iter(result.values())) == DayStatus.GREEN
