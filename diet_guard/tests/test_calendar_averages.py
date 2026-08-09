"""Tests for _calendar_view.averages_text: the History tab's averages line."""

from __future__ import annotations

from datetime import date

from diet_guard._budget_history import EPOCH_DAY, BudgetEntry, BudgetSchedule
from diet_guard._calendar_view import averages_text


def _flat(budget: int) -> BudgetSchedule:
    return BudgetSchedule(
        (BudgetEntry(EPOCH_DAY, budget, "1970-01-01T00:00:00+00:00"),),
        default=budget,
    )


class TestAveragesText:
    def test_names_both_periods(self) -> None:
        text = averages_text({}, schedule=_flat(2000), today=date(2026, 1, 14))
        assert "week" in text
        assert "month" in text

    def test_says_it_stops_at_yesterday(self) -> None:
        text = averages_text({}, schedule=_flat(2000), today=date(2026, 1, 14))
        assert "to yesterday" in text

    def test_empty_log_reads_no_data_not_zero(self) -> None:
        text = averages_text({}, schedule=_flat(2000), today=date(2026, 1, 14))
        assert "no data" in text
        assert "0 kcal" not in text

    def test_renders_the_average_and_its_band(self) -> None:
        # Mon-Tue of the week containing Wed 2026-01-14, at 3000 kcal each
        # against a 2000 budget: 150% of budget, comfortably "very over".
        log = {
            "2026-01-12": [{"kcal": 3000.0}],
            "2026-01-13": [{"kcal": 3000.0}],
        }
        text = averages_text(log, schedule=_flat(2000), today=date(2026, 1, 14))
        assert "week 3000 kcal (very over)" in text

    def test_under_budget_reads_under(self) -> None:
        log = {"2026-01-12": [{"kcal": 1500.0}]}
        text = averages_text(log, schedule=_flat(2000), today=date(2026, 1, 14))
        assert "week 1500 kcal (under)" in text

    def test_slightly_over_reads_slightly_over(self) -> None:
        log = {"2026-01-12": [{"kcal": 2200.0}]}
        text = averages_text(log, schedule=_flat(2000), today=date(2026, 1, 14))
        assert "week 2200 kcal (slightly over)" in text

    def test_today_is_not_averaged_in(self) -> None:
        log = {"2026-01-14": [{"kcal": 9000.0}]}
        text = averages_text(log, schedule=_flat(2000), today=date(2026, 1, 14))
        assert "9000" not in text

    def test_defaults_to_the_real_today(self) -> None:
        assert "week" in averages_text({}, schedule=_flat(2000))
