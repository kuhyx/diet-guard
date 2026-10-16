"""Tests for _gate.py — the slot/state composition that decides locking.

The slot arithmetic and the logged-slot state are both exercised elsewhere, so
here the logged set is mocked and ``now`` is injected to drive each decision.
"""

from __future__ import annotations

from datetime import UTC, date, datetime, time, timedelta
from typing import TYPE_CHECKING
from unittest.mock import patch

import freedays
import sickdays

from diet_guard._estimator import Nutrition
from diet_guard._gate import due_slots, gate_is_due, gate_message
from diet_guard._state import log_meal, now_local
from diet_guard._state_today import logged_slots_today, today_total_kcal

if TYPE_CHECKING:
    from pathlib import Path


def _at(hour: int) -> datetime:
    """Return a fixed local datetime at ``hour``."""
    return datetime(2026, 1, 1, hour, 0, tzinfo=UTC)


def _logged(slots: set[int]) -> object:
    """Patch the logged-slots source so the decision is deterministic."""
    return patch(
        "diet_guard._gate.logged_slots_today",
        return_value=slots,
    )


class TestDueSlots:
    """Elapsed-but-unlogged slots."""

    def test_injected_now(self) -> None:
        """With 08:00 logged at 13:00, only 12:00 is due."""
        with _logged({480}):
            assert due_slots(_at(13)) == (720,)

    def test_default_now_uses_clock(self) -> None:
        """Omitting ``now`` reads the real clock (mocked here for determinism)."""
        with (
            _logged(set()),
            patch(
                "diet_guard._gate.now_local",
                return_value=_at(9),
            ),
        ):
            assert due_slots() == (480,)


class TestGateIsDue:
    """The boolean lock decision."""

    def test_due_when_a_slot_is_missing(self) -> None:
        """A missing elapsed slot warrants a lock."""
        with _logged(set()):
            assert gate_is_due(_at(13)) is True

    def test_not_due_when_all_logged(self) -> None:
        """Everything elapsed is logged -> no lock."""
        with _logged({480, 720}):
            assert gate_is_due(_at(13)) is False


class TestGateMessage:
    """The human-readable reason line."""

    def test_all_logged(self) -> None:
        """Nothing missing -> the up-to-date message."""
        with _logged({480, 720}):
            assert "up to date" in gate_message(_at(13))

    def test_single_missing(self) -> None:
        """One missing slot -> singular phrasing."""
        with _logged({480}):
            assert gate_message(_at(13)) == "Log your 12:00 meal to unlock."

    def test_multiple_missing(self) -> None:
        """Several missing slots -> plural phrasing listing them."""
        with _logged(set()):
            message = gate_message(_at(17))
        assert message == "Log your meals for 08:00, 12:00, 16:00 to unlock."


class TestFreeDays:
    """The shared pool stands the gate down entirely."""

    def test_a_free_day_leaves_nothing_due(self, tmp_path: Path) -> None:
        with _logged(set()):
            assert due_slots(_at(20)), "precondition: slots are due without a free day"
            freedays.mark(
                _at(20).date(),
                paths=freedays.Paths.under(tmp_path / "freedays"),
                now=_at(20).date(),
            )
            assert due_slots(_at(20)) == ()
            assert not gate_is_due(_at(20))

    def test_a_free_day_on_another_date_changes_nothing(self, tmp_path: Path) -> None:
        with _logged(set()):
            freedays.mark(
                date(2026, 12, 24),
                paths=freedays.Paths.under(tmp_path / "freedays"),
                now=_at(20).date(),
            )
            assert due_slots(_at(20))
            assert gate_is_due(_at(20))

    def test_an_unreadable_pool_leaves_the_gate_armed(self, tmp_path: Path) -> None:
        """Fail closed: a corrupt pool must not switch the gate off."""
        pool_dir = tmp_path / "freedays"
        pool_dir.mkdir(exist_ok=True)
        (pool_dir / "free_days.json").write_text("{ not json", encoding="utf-8")
        with _logged(set()):
            assert gate_is_due(_at(20))


def _mark_sick(tmp_path: Path, day: date, keep: tuple[str, ...] = ()) -> None:
    """Put ``day`` in the (temp) sick-day pool; the redirect lives in conftest."""
    sickdays.add_sick_day(
        day,
        keep=keep,
        is_free=lambda _day: False,
        paths=sickdays.Paths.under(tmp_path / "sickdays"),
        now=day,
    )


class TestSickDays:
    """The sick-day pool stands the gate down, like a free day."""

    def test_a_sick_day_leaves_nothing_due(self, tmp_path: Path) -> None:
        with _logged(set()):
            assert due_slots(_at(20)), "precondition: slots are due without a sick day"
            _mark_sick(tmp_path, _at(20).date())
            assert due_slots(_at(20)) == ()
            assert not gate_is_due(_at(20))
            assert gate_message(_at(20)) == "All meals are logged. You're up to date."

    def test_a_sick_day_that_keeps_diet_stays_armed(self, tmp_path: Path) -> None:
        """A kept locker behaves exactly as on a normal day."""
        with _logged(set()):
            _mark_sick(tmp_path, _at(20).date(), keep=(sickdays.LOCKER_DIET,))
            assert due_slots(_at(20))
            assert gate_is_due(_at(20))

    def test_a_sick_day_keeping_another_locker_still_stands_down(
        self, tmp_path: Path
    ) -> None:
        with _logged(set()):
            _mark_sick(
                tmp_path,
                _at(20).date(),
                keep=(sickdays.LOCKER_WORKOUT, sickdays.LOCKER_ALARM),
            )
            assert due_slots(_at(20)) == ()

    def test_a_sick_day_on_another_date_changes_nothing(self, tmp_path: Path) -> None:
        with _logged(set()):
            _mark_sick(tmp_path, date(2026, 12, 24))
            assert due_slots(_at(20))
            assert gate_is_due(_at(20))

    def test_the_day_after_a_sick_day_is_armed_again(self, tmp_path: Path) -> None:
        _mark_sick(tmp_path, _at(20).date())
        tomorrow = _at(20) + timedelta(days=1)
        with _logged(set()):
            assert gate_is_due(tomorrow)

    def test_an_unreadable_pool_leaves_the_gate_armed(self, tmp_path: Path) -> None:
        """Fail closed: a corrupt pool must not switch the gate off."""
        pool_dir = tmp_path / "sickdays"
        pool_dir.mkdir(exist_ok=True)
        (pool_dir / "sick_days.json").write_text("{ not json", encoding="utf-8")
        with _logged(set()):
            assert gate_is_due(_at(20))

    def test_logging_still_works_on_a_sick_day(self, tmp_path: Path) -> None:
        """The gate stands down; the log does not: a meal is still recorded."""
        today = now_local().date()
        _mark_sick(tmp_path, today)
        log_meal("soup", Nutrition(300, 10, 30, 5, 250, "manual"), slot=480)
        assert logged_slots_today() == {480}
        assert today_total_kcal() == 300
        late = datetime.combine(today, time(23, 0), tzinfo=now_local().tzinfo)
        assert not gate_is_due(late)
