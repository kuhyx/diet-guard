"""Tests for _cli.py — argument parsing and subcommand dispatch.

Subsystems (budget, resolution, logging, the gate window) are mocked so each
command's branches are exercised without touching real state or opening a
window; stdin is scripted via ``StringIO`` and stdout captured with ``capsys``.
"""

from __future__ import annotations

import io
from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _cli
from diet_guard._budget import (
    BudgetFileCorruptError,
    BudgetNotInitializedError,
    write_budget,
)
from diet_guard._cli import _eaten_grams, _Portion, main
from diet_guard._estimator import Nutrition

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
    """The budget-setting init command."""

    def test_valid_male(
        self, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """Valid inputs write a budget and print the computed value."""
        _feed(monkeypatch, _VALID_INIT)
        assert main(["init"]) == 0
        assert "computed" in capsys.readouterr().out

    def test_valid_female(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """The female sex branch is accepted."""
        _feed(monkeypatch, "80\n169\n26\nf\n1.375\n180\n")
        assert main(["init"]) == 0

    def test_non_number_aborts(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """A non-numeric input sets nothing and returns the error code."""
        _feed(monkeypatch, "heavy\n")
        assert main(["init"]) == 2

    def test_bad_sex_aborts(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """An unrecognised sex answer sets nothing."""
        _feed(monkeypatch, "80\n169\n26\nx\n1.375\n180\n")
        assert main(["init"]) == 2


class TestSummary:
    """The budget-remaining summary line."""

    def test_not_initialized(self, capsys: pytest.CaptureFixture[str]) -> None:
        """No budget yet -> a guiding hint, no crash."""
        with patch.object(_cli, "daily_budget", side_effect=BudgetNotInitializedError):
            _cli._print_summary()
        assert "budget not set" in capsys.readouterr().out

    def test_file_corrupt(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A corrupt budget file is reported plainly."""
        with patch.object(_cli, "daily_budget", side_effect=BudgetFileCorruptError):
            _cli._print_summary()
        assert "corrupt" in capsys.readouterr().out

    def test_remaining_shown(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A valid budget prints how much is left."""
        write_budget(2000)
        _cli._print_summary()
        assert "left" in capsys.readouterr().out


class TestAte:
    """Logging a meal from the command line."""

    def test_logs_and_summarizes(self, capsys: pytest.CaptureFixture[str]) -> None:
        """A resolved meal is logged, banked, and summarized."""
        write_budget(2000)
        with patch.object(_cli, "resolve_nutrition", return_value=_NUT):
            assert main(["ate", "big mac"]) == 0
        assert "logged:" in capsys.readouterr().out

    def test_note_printed_for_assumed_weight(
        self, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """An assumed per-item weight prints its caveat."""
        write_budget(2000)
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
        write_budget(2000)
        main(["ate", "lunch", "--kcal", "500"])
        capsys.readouterr()
        assert main(["status"]) == 0
        out = capsys.readouterr().out
        assert "slots:" in out
        assert "macros:" in out

    def test_status_empty(self, capsys: pytest.CaptureFixture[str]) -> None:
        """With nothing logged, status still prints the slot/summary lines."""
        write_budget(2000)
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
        write_budget(2000)
        main(["ate", "snack", "--kcal", "100"])
        capsys.readouterr()
        assert main(["undo"]) == 0
        assert "removed:" in capsys.readouterr().out


class TestGate:
    """Dispatch wiring for the gate subcommand.

    cmd_gate()'s own branches are tested directly in test_cli_gate.py,
    where it lives after the 500-line split.
    """

    def test_dispatches_to_cmd_gate(self) -> None:
        with patch.object(_cli, "cmd_gate", return_value=0) as mock_cmd_gate:
            assert main(["gate", "--demo"]) == 0
        mock_cmd_gate.assert_called_once_with(_cli._emit, check=False, demo=True)


class TestSync:
    """Dispatch wiring for the sync subcommand.

    cmd_sync()'s own branches (success/SyncError/GitHubSyncError) are tested
    directly in test_cli_sync.py, where it lives after the 500-line split.
    """

    def test_dispatches_to_cmd_sync(self) -> None:
        with patch.object(_cli, "cmd_sync", return_value=0) as mock_cmd_sync:
            assert main(["sync"]) == 0
        mock_cmd_sync.assert_called_once_with(_cli._emit)
