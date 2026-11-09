"""Tests for _calendar_view.averages_text: the History tab's averages line."""

from __future__ import annotations

from datetime import date

from diet_guard import _gatelock_glyphs as g
from diet_guard._budget_history import EPOCH_DAY, BudgetEntry, BudgetSchedule
from diet_guard._calendar_view import averages_text


def _flat(budget: int) -> BudgetSchedule:
    return BudgetSchedule(
        (BudgetEntry(EPOCH_DAY, budget, "1970-01-01T00:00:00+00:00"),),
        default=budget,
    )


_WEEK = f"{g.AVERAGE} {g.SPAN['week']} "
_MONTH = f"{g.AVERAGE} {g.SPAN['month']} "


class TestAveragesText:
    def test_names_both_periods(self) -> None:
        text = averages_text({}, schedule=_flat(2000), today=date(2026, 1, 14))
        assert _WEEK in text
        assert _MONTH in text

    def test_empty_log_reads_no_value_not_zero(self) -> None:
        text = averages_text({}, schedule=_flat(2000), today=date(2026, 1, 14))
        assert text == f"{_WEEK}{g.NO_VALUE}   {_MONTH}{g.NO_VALUE}"
        assert "0 kcal" not in text

    def test_renders_the_average_and_its_band(self) -> None:
        # Mon-Tue of the week containing Wed 2026-01-14, at 3000 kcal each
        # against a 2000 budget: 150% of budget, comfortably very over.
        log = {
            "2026-01-12": [{"kcal": 3000.0}],
            "2026-01-13": [{"kcal": 3000.0}],
        }
        text = averages_text(log, schedule=_flat(2000), today=date(2026, 1, 14))
        assert f"{_WEEK}3000 kcal {g.BAND['very_over']}" in text

    def test_under_budget_band(self) -> None:
        log = {"2026-01-12": [{"kcal": 1500.0}]}
        text = averages_text(log, schedule=_flat(2000), today=date(2026, 1, 14))
        assert f"{_WEEK}1500 kcal {g.BAND['under']}" in text

    def test_slightly_over_band(self) -> None:
        log = {"2026-01-12": [{"kcal": 2200.0}]}
        text = averages_text(log, schedule=_flat(2000), today=date(2026, 1, 14))
        assert f"{_WEEK}2200 kcal {g.BAND['slightly_over']}" in text

    def test_today_is_not_averaged_in(self) -> None:
        log = {"2026-01-14": [{"kcal": 9000.0}]}
        text = averages_text(log, schedule=_flat(2000), today=date(2026, 1, 14))
        assert "9000" not in text

    def test_defaults_to_the_real_today(self) -> None:
        assert _WEEK in averages_text({}, schedule=_flat(2000))
