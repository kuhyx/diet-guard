"""Tests for _slots.resolve_future_when — a pre-logged future meal's slot.

Split out of test_slots.py for the repo's 250-line cap.
"""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from diet_guard._meal_schedule import DEFAULT_SCHEDULE, MealSchedule
from diet_guard._slots import day_slots, resolve_future_when


def _at(hour: int) -> datetime:
    """Return a fixed local datetime at ``hour`` (date is irrelevant here)."""
    return datetime(2026, 1, 1, hour, 0, tzinfo=UTC)


class TestResolveFutureWhen:
    """Validation and construction for a pre-logged future meal's datetime."""

    def test_valid_future_date_and_slot_hour(self) -> None:
        """A future date on a real slot hour resolves to that datetime."""
        now = _at(10)
        when = resolve_future_when("2026-01-02", 12, DEFAULT_SCHEDULE, now)
        assert when == datetime(2026, 1, 2, 12, 0, tzinfo=UTC)

    def test_preserves_nows_timezone(self) -> None:
        """The returned datetime carries ``now``'s tzinfo, not a bare one."""
        now = _at(10)
        when = resolve_future_when("2026-01-02", 8, DEFAULT_SCHEDULE, now)
        assert when.tzinfo == now.tzinfo

    def test_rejects_malformed_date(self) -> None:
        """A date string that doesn't parse raises ValueError."""
        with pytest.raises(ValueError, match="invalid date"):
            resolve_future_when("not-a-date", 8, DEFAULT_SCHEDULE, _at(10))

    def test_rejects_hour_not_a_slot(self) -> None:
        """An hour that isn't one of the schedule's slots raises ValueError."""
        with pytest.raises(ValueError, match="not a meal slot"):
            resolve_future_when("2026-01-02", 13, DEFAULT_SCHEDULE, _at(10))

    def test_rejects_todays_date(self) -> None:
        """Today's own date is not "future", even on a real slot hour."""
        now = datetime(2026, 1, 1, 10, 0, tzinfo=UTC)
        with pytest.raises(ValueError, match="not a future date"):
            resolve_future_when("2026-01-01", 12, DEFAULT_SCHEDULE, now)

    def test_rejects_past_date(self) -> None:
        """A date before today raises ValueError."""
        now = datetime(2026, 1, 5, 10, 0, tzinfo=UTC)
        with pytest.raises(ValueError, match="not a future date"):
            resolve_future_when("2026-01-01", 12, DEFAULT_SCHEDULE, now)

    def test_accepts_every_configured_slot_hour(self) -> None:
        """Every hour the schedule actually opens is accepted, not just one."""
        schedule = MealSchedule(8, 20, 5)
        now = _at(10)
        for hour in day_slots(schedule):
            when = resolve_future_when("2026-01-02", hour, schedule, now)
            assert when.hour == hour
