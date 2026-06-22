"""Tests for the gate subcommand's handler, split out of test_cli.py
alongside its source module (see _cli_gate.py's module docstring).
"""

from __future__ import annotations

from unittest.mock import MagicMock, patch

from diet_guard import _cli_gate
from diet_guard._cli_gate import cmd_gate


class TestCmdGate:
    """The gate subcommand's three modes."""

    def test_check_due(self) -> None:
        """--check exits 1 and announces a due lock."""
        lines: list[str] = []
        with patch.object(_cli_gate, "gate_is_due", return_value=True):
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
        """A bare gate that is due opens the real window."""
        gate = MagicMock()
        with (
            patch.object(_cli_gate, "gate_is_due", return_value=True),
            patch.object(_cli_gate, "MealGate", return_value=gate),
            patch.object(_cli_gate, "acquire_gate_lock", return_value=MagicMock()),
            patch.object(_cli_gate, "release_gate_lock"),
            patch.object(_cli_gate, "wait_for_display", return_value=True),
        ):
            assert cmd_gate([].append, check=False, demo=False) == 0
        gate.run.assert_called_once()

    def test_gate_already_running(self) -> None:
        """A held single-instance lock means a second window is not opened."""
        lines: list[str] = []
        with (
            patch.object(_cli_gate, "gate_is_due", return_value=True),
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
            patch.object(_cli_gate, "acquire_gate_lock", return_value=MagicMock()),
            patch.object(_cli_gate, "release_gate_lock"),
            patch.object(_cli_gate, "wait_for_display", return_value=False),
            patch.object(_cli_gate, "MealGate") as factory,
        ):
            assert cmd_gate(lines.append, check=False, demo=False) == 0
        factory.assert_not_called()
        assert "display not ready" in lines[0]
