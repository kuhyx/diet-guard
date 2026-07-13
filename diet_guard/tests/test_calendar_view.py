"""Tests for the pure (no-Tk) calendar grid math and status text."""

from __future__ import annotations

from datetime import date

from diet_guard._calendar_view import (
    CalendarCell,
    build_month_cells,
    cell_style,
    streaks_text,
    ytd_text,
)
from diet_guard._daystatus import DayStatus


class TestBuildMonthCells:
    """Boundary matrix for :func:`build_month_cells`."""

    def test_blank_cells_outside_the_month_have_no_day_or_status(self) -> None:
        # July 2026 starts on a Wednesday, so the first row has leading blanks.
        weeks = build_month_cells(2026, 7, {}, today=date(2026, 7, 31))
        assert weeks[0][0] == CalendarCell(day=None, status=None)

    def test_a_day_present_in_the_status_map_carries_its_status(self) -> None:
        weeks = build_month_cells(
            2026,
            7,
            {"2026-07-15": DayStatus.GREEN},
            today=date(2026, 7, 31),
        )
        cell = next(c for week in weeks for c in week if c.day == 15)
        assert cell.status is DayStatus.GREEN

    def test_a_past_day_absent_from_the_status_map_is_not_logged(self) -> None:
        weeks = build_month_cells(2026, 7, {}, today=date(2026, 7, 31))
        cell = next(c for week in weeks for c in week if c.day == 1)
        assert cell.status is DayStatus.NOT_LOGGED

    def test_a_future_day_is_neutral_not_not_logged(self) -> None:
        weeks = build_month_cells(2026, 7, {}, today=date(2026, 7, 10))
        cell = next(c for week in weeks for c in week if c.day == 15)
        assert cell.status is None

    def test_today_itself_is_classified_not_treated_as_future(self) -> None:
        weeks = build_month_cells(
            2026,
            7,
            {"2026-07-10": DayStatus.RED},
            today=date(2026, 7, 10),
        )
        cell = next(c for week in weeks for c in week if c.day == 10)
        assert cell.status is DayStatus.RED

    def test_none_status_map_renders_every_past_day_neutral(self) -> None:
        weeks = build_month_cells(2026, 7, None, today=date(2026, 7, 31))
        cell = next(c for week in weeks for c in week if c.day == 1)
        assert cell.status is None

    def test_defaults_today_to_the_real_current_date(self) -> None:
        # No explicit `today` -- exercises the now_local() fallback branch.
        weeks = build_month_cells(2020, 1, {})
        assert weeks[0][0].day in (None, 1)

    def test_a_28_day_february_produces_four_or_five_weeks(self) -> None:
        weeks = build_month_cells(2026, 2, {}, today=date(2026, 2, 28))
        assert len(weeks) in (4, 5)

    def test_a_31_day_month_starting_on_saturday_produces_six_weeks(self) -> None:
        # August 2026 starts on a Saturday and has 31 days -> 6 rows.
        weeks = build_month_cells(2026, 8, {}, today=date(2026, 8, 31))
        assert len(weeks) == 6

    def test_every_day_of_the_month_is_present_exactly_once(self) -> None:
        weeks = build_month_cells(2026, 7, {}, today=date(2026, 7, 31))
        days = [cell.day for week in weeks for cell in week if cell.day is not None]
        assert days == list(range(1, 32))


class TestCellStyle:
    """Boundary matrix for :func:`cell_style`."""

    def test_none_status_is_neutral(self) -> None:
        bg, _fg, outline = cell_style(None)
        assert bg == outline

    def test_not_logged_is_black_with_a_visible_outline(self) -> None:
        bg, _fg, outline = cell_style(DayStatus.NOT_LOGGED)
        assert bg == "#000000"
        assert outline != bg

    def test_green_yellow_red_each_style_distinctly(self) -> None:
        styles = {
            status: cell_style(status)
            for status in (DayStatus.GREEN, DayStatus.YELLOW, DayStatus.RED)
        }
        assert len({style[0] for style in styles.values()}) == 3


class TestStreaksText:
    """:func:`streaks_text` boundary cases (singular/plural, zero)."""

    def test_zero_streaks_render_as_zero_days(self) -> None:
        text = streaks_text({}, today=date(2026, 7, 13))
        assert "0 days" in text

    def test_a_one_day_streak_uses_the_singular(self) -> None:
        text = streaks_text(
            {"2026-07-13": DayStatus.GREEN},
            today=date(2026, 7, 13),
        )
        assert "Logging streak: 1 day " in text
        assert "Adherence streak: 1 day" in text


class TestYtdText:
    """:func:`ytd_text` renders the tally's three counts."""

    def test_reports_logged_elapsed_and_adherent_counts(self) -> None:
        status_map_ = {
            "2026-01-01": DayStatus.GREEN,
            "2026-01-02": DayStatus.RED,
        }
        text = ytd_text(status_map_, today=date(2026, 1, 10))
        assert "logged 2/10 days" in text
        assert "1 within budget" in text
