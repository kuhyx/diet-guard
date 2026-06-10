"""Tests for _cli.py — argument parsing and subcommand dispatch.

Subsystems (budget, resolution, logging, the gate window) are mocked so each
command's branches are exercised without touching real state or opening a
window; stdin is scripted via ``StringIO`` and stdout captured with ``capsys``.
"""

from __future__ import annotations

import io
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

from python_pkg.diet_guard import _cli
from python_pkg.diet_guard._budget import (
    BudgetLockedError,
    BudgetNotInitializedError,
    BudgetSealBrokenError,
    seal_budget,
)
from python_pkg.diet_guard._cli import _eaten_grams, _Portion, main
from python_pkg.diet_guard._estimator import Nutrition

if TYPE_CHECKING:
    import pytest

_NUT = Nutrition(250, 12, 30, 10, 200, "manual")
_VALID_INIT = "80\n169\n26\nm\n1.375\n180\n"


def _feed(monkeypatch: pytest.MonkeyPatch, text: str) -> None:
    """Point stdin at scripted ``text`` for the prompts a command reads."""
    monkeypatch.setattr("sys.stdin", io.StringIO(text))


class TestEatenGrams:
    """Turning a portion into grams, with the assumption note."""

    def test_count_of_known_staple(self) -> None:
        """A count of a known staple multiplies by its unit weight, no note."""
        grams, note = _eaten_grams(
            "apple", _Portion(grams=None, count=5, per_grams=None)
        )
        assert grams == 5 * 182
        assert note is None

    def test_count_of_unknown_item_warns(self) -> None:
        """A count of an unknown item uses the default and flags the assumption."""
        grams, note = _eaten_grams(
            "mystery", _Portion(grams=None, count=3, per_grams=None)
        )
        assert grams is not None
        assert note is not None

    def test_explicit_grams(self) -> None:
        """An explicit gram portion passes straight through."""
        grams, note = _eaten_grams("x", _Portion(grams=300, count=None, per_grams=None))
        assert grams == 300
        assert note is None


class TestInit:
    """The budget-sealing init command."""

    def test_valid_male(
        self, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Valid inputs seal a budget and print the lock hint, not the number."""
        _feed(monkeypatch, _VALID_INIT)
        assert main(["init"]) == 0
        assert "sealed" in capsys.readouterr().out

    def test_valid_female(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """The female sex branch is accepted."""
        _feed(monkeypatch, "80\n169\n26\nf\n1.375\n180\n")
        assert main(["init"]) == 0

    def test_non_number_aborts(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """A non-numeric input seals nothing and returns the error code."""
        _feed(monkeypatch, "heavy\n")
        assert main(["init"]) == 2

    def test_bad_sex_aborts(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """An unrecognised sex answer seals nothing."""
        _feed(monkeypatch, "80\n169\n26\nx\n1.375\n180\n")
        assert main(["init"]) == 2

    def test_locked_budget(
        self, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """A locked file surfaces the unlock instructions and a failure code."""
        _feed(monkeypatch, _VALID_INIT)
        with patch.object(_cli, "seal_budget", side_effect=BudgetLockedError):
            assert main(["init"]) == 1
        assert "locked" in capsys.readouterr().out


class TestSummary:
    """The budget-remaining summary line."""

    def test_not_initialized(self, capsys: pytest.CaptureFixture[str]) -> None:
        """No budget yet -> a guiding hint, no crash."""
        with patch.object(_cli, "daily_budget", side_effect=BudgetNotInitializedError):
            _cli._print_summary()
        assert "budget not set" in capsys.readouterr().out

    def test_seal_broken(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A broken seal is reported plainly."""
        with patch.object(_cli, "daily_budget", side_effect=BudgetSealBrokenError):
            _cli._print_summary()
        assert "seal broken" in capsys.readouterr().out

    def test_remaining_shown(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A valid budget prints how much is left."""
        seal_budget(2000)
        _cli._print_summary()
        assert "left" in capsys.readouterr().out


class TestAte:
    """Logging a meal from the command line."""

    def test_logs_and_summarizes(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A resolved meal is logged, banked, and summarized."""
        seal_budget(2000)
        with patch.object(_cli, "resolve_nutrition", return_value=_NUT):
            assert main(["ate", "big mac"]) == 0
        assert "logged:" in capsys.readouterr().out

    def test_note_printed_for_assumed_weight(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """An assumed per-item weight prints its caveat."""
        seal_budget(2000)
        with patch.object(_cli, "resolve_nutrition", return_value=_NUT):
            main(["ate", "mystery", "--count", "3"])
        assert "assumed" in capsys.readouterr().out

    def test_unresolved_food(self, capsys: pytest.CaptureFixture[str]) -> None:
        """An unresolvable food returns a failure and a manual-entry hint."""
        with patch.object(_cli, "resolve_nutrition", return_value=None):
            assert main(["ate", "nonsense"]) == 1
        assert "--kcal" in capsys.readouterr().out


class TestStatus:
    """The status report."""

    def test_status_with_entries(self, capsys: pytest.CaptureFixture[str]) -> None:
        """Logged entries, slots, summary, and macros all print."""
        seal_budget(2000)
        main(["ate", "lunch", "--kcal", "500"])
        capsys.readouterr()
        assert main(["status"]) == 0
        out = capsys.readouterr().out
        assert "slots:" in out
        assert "macros:" in out

    def test_status_empty(self, capsys: pytest.CaptureFixture[str]) -> None:
        """With nothing logged, status still prints the slot/summary lines."""
        seal_budget(2000)
        assert main(["status"]) == 0
        assert "slots:" in capsys.readouterr().out

    def test_macro_status_with_target(self, capsys: pytest.CaptureFixture[str]) -> None:
        """When a protein target is known, it is shown alongside the macros."""
        with patch.object(_cli, "protein_target_g", return_value=144.0):
            _cli._print_macro_status()
        assert "protein" in capsys.readouterr().out

    def test_macro_status_without_target(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """With no target, only the running macros are shown."""
        with patch.object(_cli, "protein_target_g", return_value=None):
            _cli._print_macro_status()
        out = capsys.readouterr().out
        assert "macros:" in out
        assert "protein" not in out

    def test_slot_status_all_marks(self, capsys: pytest.CaptureFixture[str]) -> None:
        """The slot line shows logged / DUE / upcoming together."""
        with (
            patch.object(_cli, "logged_slots_today", return_value={8}),
            patch.object(_cli, "due_slots", return_value=[12]),
        ):
            _cli._print_slot_status()
        out = capsys.readouterr().out
        assert "logged" in out
        assert "DUE" in out
        assert "upcoming" in out


class TestUndo:
    """Removing the most recent entry."""

    def test_nothing_to_undo(self, capsys: pytest.CaptureFixture[str]) -> None:
        """An empty day reports nothing to undo."""
        assert main(["undo"]) == 0
        assert "nothing to undo" in capsys.readouterr().out

    def test_undo_removes_entry(self, capsys: pytest.CaptureFixture[str]) -> None:
        """Undo removes and reports the last entry."""
        seal_budget(2000)
        main(["ate", "snack", "--kcal", "100"])
        capsys.readouterr()
        assert main(["undo"]) == 0
        assert "removed:" in capsys.readouterr().out


class TestGate:
    """The gate subcommand's three modes."""

    def test_check_due(self, capsys: pytest.CaptureFixture[str]) -> None:
        """--check exits 1 and announces a due lock."""
        with patch.object(_cli, "gate_is_due", return_value=True):
            assert main(["gate", "--check"]) == 1
        assert "due" in capsys.readouterr().out

    def test_check_not_due(self) -> None:
        """--check exits 0 when no lock is needed."""
        with patch.object(_cli, "gate_is_due", return_value=False):
            assert main(["gate", "--check"]) == 0

    def test_demo_opens_window(self) -> None:
        """--demo always builds and runs the gate window."""
        gate = MagicMock()
        with (
            patch.object(_cli, "MealGate", return_value=gate) as factory,
            patch.object(_cli, "acquire_gate_lock", return_value=MagicMock()),
            patch.object(_cli, "release_gate_lock"),
        ):
            assert main(["gate", "--demo"]) == 0
        factory.assert_called_once_with(demo_mode=True)
        gate.run.assert_called_once()

    def test_bare_gate_not_due(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A bare gate with nothing due just reports and exits."""
        with patch.object(_cli, "gate_is_due", return_value=False):
            assert main(["gate"]) == 0
        assert "no lock needed" in capsys.readouterr().out

    def test_bare_gate_due_opens_window(self) -> None:
        """A bare gate that is due opens the real window."""
        gate = MagicMock()
        with (
            patch.object(_cli, "gate_is_due", return_value=True),
            patch.object(_cli, "MealGate", return_value=gate),
            patch.object(_cli, "acquire_gate_lock", return_value=MagicMock()),
            patch.object(_cli, "release_gate_lock"),
        ):
            assert main(["gate"]) == 0
        gate.run.assert_called_once()

    def test_gate_already_running(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A held single-instance lock means a second window is not opened."""
        with (
            patch.object(_cli, "gate_is_due", return_value=True),
            patch.object(_cli, "acquire_gate_lock", return_value=None),
            patch.object(_cli, "MealGate") as factory,
        ):
            assert main(["gate"]) == 0
        factory.assert_not_called()
        assert "already running" in capsys.readouterr().out

    def test_gate_due_but_display_not_ready_defers(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """A due gate whose display never comes up defers without a window."""
        with (
            patch.object(_cli, "gate_is_due", return_value=True),
            patch.object(_cli, "acquire_gate_lock", return_value=MagicMock()),
            patch.object(_cli, "release_gate_lock"),
            patch.object(_cli, "wait_for_display", return_value=False),
            patch.object(_cli, "MealGate") as factory,
        ):
            assert main(["gate"]) == 0
        factory.assert_not_called()
        assert "display not ready" in capsys.readouterr().out
