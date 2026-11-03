"""Hold contract (holds-v0.1.0): the gate never locks nor owes a slot in a hold.

``holds`` is faked through ``sys.modules`` so these tests pin diet_guard's side
of the contract: ``holds.covers("diet", when)`` with a naive local datetime,
failing closed (= normal rules) when the package is missing or misbehaves.
"""

from __future__ import annotations

from datetime import UTC, datetime
import sys
from types import SimpleNamespace
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

from diet_guard._gate import due_slots, gate_is_due
from diet_guard._hold import HOLD_POLL_MS, HoldWatch, hold_covers, watch_hold

if TYPE_CHECKING:
    from collections.abc import Callable

WED = datetime(2026, 11, 4, tzinfo=UTC)


def _wed(hour: int, minute: int = 0) -> datetime:
    """Return Wed 2026-11-04 at ``hour:minute`` (aware, like ``now_local``)."""
    return WED.replace(hour=hour, minute=minute)


def _install_holds(
    monkeypatch: pytest.MonkeyPatch,
    covers: Callable[[str, datetime], bool],
) -> MagicMock:
    """Install a fake ``holds`` whose ``covers`` is ``covers``."""
    spy = MagicMock(side_effect=covers)
    monkeypatch.setitem(sys.modules, "holds", SimpleNamespace(covers=spy))
    return spy


def _in_window(start: datetime, end: datetime) -> Callable[[str, datetime], bool]:
    """A ``covers`` for one hold ``[start, end)`` on naive local time."""
    lo, hi = start.replace(tzinfo=None), end.replace(tzinfo=None)
    return lambda gate, when: gate == "diet" and lo <= when < hi


def _logged(slots: set[int]) -> object:
    return patch("diet_guard._gate.logged_slots_today", return_value=slots)


class TestHoldCovers:
    """``hold_covers`` is a fail-closed wrapper over ``holds.covers``."""

    def test_asks_the_diet_gate_with_a_naive_time(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        spy = _install_holds(monkeypatch, lambda gate, when: True)
        assert hold_covers(_wed(18)) is True
        spy.assert_called_once_with("diet", _wed(18).replace(tzinfo=None))

    def test_missing_package_fails_closed(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        monkeypatch.setitem(sys.modules, "holds", None)
        assert hold_covers(_wed(18)) is False
        assert "holds unavailable" in caplog.text

    def test_a_raising_holds_fails_closed(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        def boom(gate: str, when: datetime) -> bool:
            msg = "corrupt"
            raise ValueError(msg)

        _install_holds(monkeypatch, boom)
        assert hold_covers(_wed(18)) is False
        assert "holds unavailable" in caplog.text


class TestDueSlotsInHold:
    """Wed 17:00-20:00 hold: no lock inside it, no debt for slots inside it."""

    @pytest.fixture(autouse=True)
    def _hold(self, monkeypatch: pytest.MonkeyPatch) -> None:
        _install_holds(monkeypatch, _in_window(_wed(17), _wed(20)))

    def test_nothing_due_while_the_hold_is_active(self) -> None:
        with _logged(set()):
            assert due_slots(_wed(18)) == ()
            assert not gate_is_due(_wed(18))

    def test_slot_inside_the_hold_is_not_owed_afterwards(self) -> None:
        # 08:00/12:00 unlogged and elapsed; 17:30 and 19:45 fall in the hold.
        schedule = MagicMock()
        with (
            _logged({480, 720}),
            patch("diet_guard._gate.current_schedule", return_value=schedule),
            patch(
                "diet_guard._gate.missing_slots",
                return_value=(1050, 1185),  # 17:30, 19:45
            ),
        ):
            assert due_slots(_wed(21)) == ()

    def test_slots_outside_the_hold_stay_owed(self) -> None:
        with (
            _logged(set()),
            patch(
                "diet_guard._gate.missing_slots",
                return_value=(480, 1050, 1260),  # 08:00, 17:30, 21:00
            ),
        ):
            assert due_slots(_wed(21, 30)) == (480, 1260)

    def test_hold_ending_restores_the_normal_rules(self) -> None:
        with _logged(set()):
            assert gate_is_due(_wed(16))
            assert not gate_is_due(_wed(19))
            assert gate_is_due(_wed(20, 15))

    def test_missing_holds_package_changes_nothing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setitem(sys.modules, "holds", None)
        with _logged(set()):
            assert gate_is_due(_wed(18))


class TestHoldWatch:
    """An open lock lifts within one poll interval of a hold starting."""

    def test_poll_interval_is_within_the_60_s_budget(self) -> None:
        assert 0 < HOLD_POLL_MS <= 30_000

    def test_start_schedules_the_first_check(self) -> None:
        root, close = MagicMock(), MagicMock()
        HoldWatch(root, close).start()
        root.after.assert_called_once()
        assert root.after.call_args.args[0] == HOLD_POLL_MS

    def test_watch_hold_starts_a_watch(self) -> None:
        root = MagicMock()
        watch_hold(root, MagicMock())
        root.after.assert_called_once()

    def test_no_hold_reschedules_without_closing(self) -> None:
        root, close = MagicMock(), MagicMock()
        watch = HoldWatch(root, close)
        with patch("diet_guard._hold.hold_covers", return_value=False):
            watch.tick()
        close.assert_not_called()
        root.after.assert_called_once_with(HOLD_POLL_MS, watch.tick)

    def test_hold_closes_the_lock_and_stops_polling(self) -> None:
        root, close = MagicMock(), MagicMock()
        watch = HoldWatch(root, close)
        with patch("diet_guard._hold.hold_covers", return_value=True):
            watch.tick()
        close.assert_called_once_with()
        root.after.assert_not_called()
