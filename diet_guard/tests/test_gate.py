"""Tests for _gate.py — the slot/state composition that decides locking.

The slot arithmetic and the logged-slot state are both exercised elsewhere, so
here the logged set is mocked and ``now`` is injected to drive each decision.
"""

from __future__ import annotations

from datetime import datetime, timezone
from unittest.mock import patch

from python_pkg.diet_guard._gate import due_slots, gate_is_due, gate_message


def _at(hour: int) -> datetime:
    """Return a fixed local datetime at ``hour``."""
    return datetime(2026, 1, 1, hour, 0, tzinfo=timezone.utc)


def _logged(slots: set[int]) -> object:
    """Patch the logged-slots source so the decision is deterministic."""
    return patch(
        "python_pkg.diet_guard._gate.logged_slots_today",
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
                "python_pkg.diet_guard._gate.now_local",
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
