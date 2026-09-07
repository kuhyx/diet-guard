"""Tests for _gate.py — the slot/state composition that decides locking.

The slot arithmetic and the logged-slot state are both exercised elsewhere, so
here the logged set is mocked and ``now`` is injected to drive each decision.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from typing import TYPE_CHECKING
from unittest.mock import patch

import freedays

from diet_guard._gate import due_slots, gate_is_due, gate_message

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
        with _logged({8}):
            assert due_slots(_at(13)) == (12,)

    def test_default_now_uses_clock(self) -> None:
        """Omitting ``now`` reads the real clock (mocked here for determinism)."""
        with (
            _logged(set()),
            patch(
                "diet_guard._gate.now_local",
                return_value=_at(9),
            ),
        ):
            assert due_slots() == (8,)


class TestGateIsDue:
    """The boolean lock decision."""

    def test_due_when_a_slot_is_missing(self) -> None:
        """A missing elapsed slot warrants a lock."""
        with _logged(set()):
            assert gate_is_due(_at(13)) is True

    def test_not_due_when_all_logged(self) -> None:
        """Everything elapsed is logged -> no lock."""
        with _logged({8, 12}):
            assert gate_is_due(_at(13)) is False


class TestGateMessage:
    """The human-readable reason line."""

    def test_all_logged(self) -> None:
        """Nothing missing -> the up-to-date message."""
        with _logged({8, 12}):
            assert "up to date" in gate_message(_at(13))

    def test_single_missing(self) -> None:
        """One missing slot -> singular phrasing."""
        with _logged({8}):
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
