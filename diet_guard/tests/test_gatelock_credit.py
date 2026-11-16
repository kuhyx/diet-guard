"""The open gate window notices a meal logged elsewhere (credit watch).

2026-11-16: ``watch_hold`` was the gate window's only passive watcher, so a
meal the phone (or another process) logged while the window was up changed
nothing until the user pressed Fetch. ``arm_credit_watch`` hands the shared
``gatelock.watch_credit`` the food log, the existing ``due_slots`` check and
the window's existing reconcile/close path.
"""

from __future__ import annotations

from datetime import datetime, time
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

from diet_guard import _gatelock_credit, _state
from diet_guard._gate import due_slots
from diet_guard._gatelock_credit import arm_credit_watch
from diet_guard.tests.conftest import _nutrition

if TYPE_CHECKING:
    from diet_guard._gatelock import MealGate

_FIRST, _SECOND, _THIRD = 480, 720, 960


def _evening() -> datetime:
    """17:00 local today: the 08:00, 12:00 and 16:00 slots have all elapsed."""
    return datetime.combine(_state.now_local().date(), time(17, 0)).astimezone()


def _due_at_five_pm() -> tuple[int, ...]:
    """The real ``due_slots`` check, frozen at 17:00 so it is deterministic."""
    return due_slots(_evening())


class TestArming:
    """What ``arm_credit_watch`` hands to the shared watcher."""

    def test_watches_the_real_food_log_with_the_reconcile_path(self) -> None:
        """The path is the file ``log_meal`` writes; on_credit is passed on."""
        root, on_credit = MagicMock(), MagicMock()
        with patch.object(_gatelock_credit, "watch_credit") as watch:
            arm_credit_watch(root, lambda: [_FIRST], on_credit)
        args = watch.call_args.args
        assert args[0] is root
        assert tuple(args[1]) == (_state.food_log_path(),)
        assert args[3] is on_credit

    def test_done_means_every_pending_slot_is_covered(self) -> None:
        """is_done is True only once no pending slot is still due."""
        pending = [_FIRST, _SECOND]
        with patch.object(_gatelock_credit, "watch_credit") as watch:
            arm_credit_watch(MagicMock(), lambda: pending, MagicMock())
        is_done = watch.call_args.args[2]
        with patch.object(_gatelock_credit, "due_slots", return_value=(_FIRST,)):
            assert is_done() is False
        with patch.object(_gatelock_credit, "due_slots", return_value=(_SECOND,)):
            assert is_done() is False
        with patch.object(_gatelock_credit, "due_slots", return_value=()):
            assert is_done() is True

    def test_nothing_pending_is_not_a_credit(self) -> None:
        """An empty pending list is the window's own state, not a credit."""
        with patch.object(_gatelock_credit, "watch_credit") as watch:
            arm_credit_watch(MagicMock(), list, MagicMock())
        with patch.object(_gatelock_credit, "due_slots", return_value=()):
            assert watch.call_args.args[2]() is False

    def test_pending_is_read_fresh_each_poll(self) -> None:
        """A reconcile that rebuilds the list is seen on the next poll."""
        holder = {"pending": [_FIRST]}
        with patch.object(_gatelock_credit, "watch_credit") as watch:
            arm_credit_watch(MagicMock(), lambda: holder["pending"], MagicMock())
        is_done = watch.call_args.args[2]
        with patch.object(_gatelock_credit, "due_slots", return_value=(_FIRST,)):
            assert is_done() is False
            holder["pending"] = [_SECOND]
            assert is_done() is True


class TestWithTheRealLog:
    """End to end on the real ``log_meal`` writer and the real watcher."""

    def test_a_meal_written_elsewhere_closes_the_gate(self) -> None:
        """Not done while a slot is due; the write that covers it fires once."""
        root, on_credit = MagicMock(), MagicMock()
        pending = [_FIRST, _SECOND, _THIRD]
        with patch.object(_gatelock_credit, "due_slots", _due_at_five_pm):
            arm_credit_watch(root, lambda: pending, on_credit)

            def poll() -> None:
                root.after.call_args.args[1]()

            poll()  # log absent: asked once, still due
            on_credit.assert_not_called()
            _state.log_meal("a", _nutrition(), _FIRST)
            _state.log_meal("b", _nutrition(), _SECOND)
            poll()  # moved, but the 16:00 slot is still owed
            on_credit.assert_not_called()
            _state.log_meal("c", _nutrition(), _THIRD)
            poll()
        on_credit.assert_called_once_with()
        assert root.after.call_count == 3  # armed + two re-arms, none after fire


class TestRunWiring:
    """``MealGate.run`` arms the watch and the pull in production, never in demo."""

    def test_production_run_arms_the_credit_watch_and_the_pull(
        self, gate: MealGate
    ) -> None:
        """A real (non-demo) gate watches; on_credit is the reconcile path."""
        gate.demo_mode = False
        with (
            patch.object(gate._lock, "run"),
            patch("diet_guard._gatelock.watch_hold"),
            patch("diet_guard._gatelock.arm_credit_watch") as arm,
            patch("diet_guard._gatelock.arm_peer_pull") as pull,
        ):
            gate.run()
        root, pending, on_credit = arm.call_args.args
        assert root is gate.root
        assert pending() is gate._pending
        assert on_credit == gate._reconcile_after_fetch
        pull.assert_called_once_with(gate)

    def test_demo_run_never_arms_either(self, gate: MealGate) -> None:
        """A demo window owes a synthetic slot: it must not close itself."""
        with (
            patch.object(gate._lock, "run"),
            patch("diet_guard._gatelock.watch_hold"),
            patch("diet_guard._gatelock.arm_credit_watch") as arm,
            patch("diet_guard._gatelock.arm_peer_pull") as pull,
        ):
            gate.run()
        arm.assert_not_called()
        pull.assert_not_called()

    def test_the_pull_slot_is_the_fetch_buttons_slot(self, gate: MealGate) -> None:
        """One in-flight pull for both writers: the public slot is the button's."""
        assert gate.fetch_result is None
        marker = MagicMock()
        gate.fetch_result = marker
        assert gate._fetch_result is marker
