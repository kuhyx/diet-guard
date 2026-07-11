"""Tests for the gate subcommand's handler, split out of test_cli.py
alongside its source module (see _cli_gate.py's module docstring).
"""

from __future__ import annotations

from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

from diet_guard import _cli_gate
from diet_guard._cli_gate import _is_due, cmd_gate
from diet_guard._estimator import Nutrition
from diet_guard._gate import gate_is_due
from diet_guard._state import log_meal


def _no_sync() -> object:
    """Neutralize the pre-lock pull (as if it found nothing) for mode tests."""
    return patch.object(_cli_gate, "pull_shared_log", return_value=None)


class TestCmdGate:
    """The gate subcommand's three modes."""

    def test_check_due(self) -> None:
        """--check exits 1 and announces a due lock."""
        lines: list[str] = []
        with patch.object(_cli_gate, "gate_is_due", return_value=True), _no_sync():
            assert cmd_gate(lines.append, check=True, demo=False) == 1
        assert "due" in lines[0]

    def test_check_not_due(self) -> None:
        """--check exits 0 when no lock is needed."""
        with patch.object(_cli_gate, "gate_is_due", return_value=False):
            assert cmd_gate([].append, check=True, demo=False) == 0

    def test_demo_opens_window(self) -> None:
        """--demo always builds and runs the gate window."""
        gate = MagicMock()
        with (
            patch.object(_cli_gate, "MealGate", return_value=gate) as factory,
            patch.object(_cli_gate, "acquire_gate_lock", return_value=MagicMock()),
            patch.object(_cli_gate, "release_gate_lock"),
            patch.object(_cli_gate, "wait_for_display", return_value=True),
        ):
            assert cmd_gate([].append, check=False, demo=True) == 0
        factory.assert_called_once_with(demo_mode=True)
        gate.run.assert_called_once()

    def test_bare_gate_not_due(self) -> None:
        """A bare gate with nothing due just reports and exits."""
        lines: list[str] = []
        with patch.object(_cli_gate, "gate_is_due", return_value=False):
            assert cmd_gate(lines.append, check=False, demo=False) == 0
        assert "no lock needed" in lines[0]

    def test_bare_gate_due_opens_window(self) -> None:
        """A bare gate that is still due after a sync opens the real window."""
        gate = MagicMock()
        with (
            patch.object(_cli_gate, "gate_is_due", return_value=True),
            _no_sync(),
            patch.object(_cli_gate, "MealGate", return_value=gate),
            patch.object(_cli_gate, "acquire_gate_lock", return_value=MagicMock()),
            patch.object(_cli_gate, "release_gate_lock"),
            patch.object(_cli_gate, "wait_for_display", return_value=True),
        ):
            assert cmd_gate([].append, check=False, demo=False) == 0
        gate.run.assert_called_once()

    def test_bare_gate_cleared_by_sync_opens_no_window(self) -> None:
        """A meal pulled in by the pre-lock sync clears the lock: no window."""
        lines: list[str] = []
        with (
            patch.object(_cli_gate, "gate_is_due", side_effect=[True, False]),
            patch.object(_cli_gate, "pull_shared_log", return_value=None),
            patch.object(_cli_gate, "MealGate") as factory,
        ):
            assert cmd_gate(lines.append, check=False, demo=False) == 0
        factory.assert_not_called()
        assert "no lock needed" in lines[0]

    def test_gate_already_running(self) -> None:
        """A held single-instance lock means a second window is not opened."""
        lines: list[str] = []
        with (
            patch.object(_cli_gate, "gate_is_due", return_value=True),
            _no_sync(),
            patch.object(_cli_gate, "acquire_gate_lock", return_value=None),
            patch.object(_cli_gate, "MealGate") as factory,
        ):
            assert cmd_gate(lines.append, check=False, demo=False) == 0
        factory.assert_not_called()
        assert "already running" in lines[0]

    def test_gate_due_but_display_not_ready_defers(self) -> None:
        """A due gate whose display never comes up defers without a window."""
        lines: list[str] = []
        with (
            patch.object(_cli_gate, "gate_is_due", return_value=True),
            _no_sync(),
            patch.object(_cli_gate, "acquire_gate_lock", return_value=MagicMock()),
            patch.object(_cli_gate, "release_gate_lock"),
            patch.object(_cli_gate, "wait_for_display", return_value=False),
            patch.object(_cli_gate, "MealGate") as factory,
        ):
            assert cmd_gate(lines.append, check=False, demo=False) == 0
        factory.assert_not_called()
        assert "display not ready" in lines[0]


class TestIsDue:
    """The decision helper only pays the network cost when a lock is due."""

    def test_not_due_skips_sync(self) -> None:
        """When nothing is due locally, no pull is attempted."""
        pull = MagicMock(return_value=None)
        with (
            patch.object(_cli_gate, "gate_is_due", return_value=False),
            patch.object(_cli_gate, "pull_shared_log", pull),
        ):
            assert _is_due([].append) is False
        pull.assert_not_called()

    def test_due_then_cleared_by_sync(self) -> None:
        """A due lock that the pull clears re-reads as not due."""
        pull = MagicMock(return_value=None)
        with (
            patch.object(_cli_gate, "gate_is_due", side_effect=[True, False]),
            patch.object(_cli_gate, "pull_shared_log", pull),
        ):
            assert _is_due([].append) is False
        pull.assert_called_once()

    def test_due_and_still_due_after_sync(self) -> None:
        """A due lock the pull cannot satisfy stays due."""
        pull = MagicMock(return_value=None)
        with (
            patch.object(_cli_gate, "gate_is_due", side_effect=[True, True]),
            patch.object(_cli_gate, "pull_shared_log", pull),
        ):
            assert _is_due([].append) is True
        pull.assert_called_once()

    def test_pull_failure_is_reported(self) -> None:
        """A failed pull emits its reason but the local decision still stands."""
        lines: list[str] = []
        with (
            patch.object(_cli_gate, "gate_is_due", side_effect=[True, True]),
            patch.object(
                _cli_gate, "pull_shared_log", return_value="sync unavailable (x)"
            ),
        ):
            assert _is_due(lines.append) is True
        assert "sync unavailable (x)" in lines[0]


class TestGateReadsFreshState:
    """The fix's whole correctness rests on the re-check reading fresh disk.

    Mocked ``gate_is_due`` tests would pass whether or not production re-reads
    state, so this one exercises the real uncached read path: a slot written to
    ``food_log.json`` (what ``run_sync`` does when it pulls a phone meal) must be
    visible to the very next ``gate_is_due`` call.
    """

    @staticmethod
    def _nutrition() -> Nutrition:
        return Nutrition(200.0, 10.0, 20.0, 5.0, 100.0, "test")

    def test_written_slot_clears_the_gate_immediately(self) -> None:
        """At 09:00 only the 08:00 slot is due; logging it flips the decision."""
        now = datetime(2026, 1, 1, 9, 0, tzinfo=timezone.utc)
        assert gate_is_due(now) is True
        log_meal("oatmeal", self._nutrition(), slot=8)
        assert gate_is_due(now) is False
