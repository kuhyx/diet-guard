"""The gate's error reporting: installed once by the CLI, into the shared spool."""

from __future__ import annotations

import json
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

from diet_guard import _cli, _errors, _gatelock
from diet_guard._gatelock import MealGate
from diet_guard.tests._gate_fixtures import fake_tk

if TYPE_CHECKING:
    from pathlib import Path

    import pytest


def test_install_keeps_the_reporter_and_writes_the_spool(tmp_path: Path) -> None:
    """The CLI's install names the gate app and its repo in every report."""
    rep = _errors.install()
    assert _errors.SLOT.reporter is rep
    assert rep.app == "diet-guard-gate"
    rep.report("uncaught.python", ValueError("deliberate"))
    line = (tmp_path / "app-errors-spool" / "diet-guard-gate.jsonl").read_text()
    entry = json.loads(line)
    assert entry["repo"] == "kuhyx/diet-guard"
    assert entry["error"] == "ValueError: deliberate"


def test_cli_main_installs_before_dispatch(monkeypatch: pytest.MonkeyPatch) -> None:
    """Every CLI run hooks errors, the gate's included."""
    install = MagicMock()
    monkeypatch.setattr(_errors, "install", install)
    monkeypatch.setitem(_cli._COMMANDS, "status", lambda _args: 0)
    assert _cli.main(["status"]) == 0
    install.assert_called_once_with()


def _run(gate: MealGate) -> None:
    """Run the gate's start-up with its Tk loop stubbed out."""
    with (
        patch.object(gate, "_lock", MagicMock()),
        patch.object(_gatelock, "watch_hold"),
    ):
        gate.run()


def test_gate_watches_stalls_once_installed(monkeypatch: pytest.MonkeyPatch) -> None:
    """A gate built after install reports its own freezes."""
    reporter = MagicMock()
    monkeypatch.setattr(_errors.SLOT, "reporter", reporter)
    with patch.object(_errors, "watch_stalls") as watch, fake_tk():
        gate = MealGate(demo_mode=True)
        watch.assert_not_called()  # the turn wait while building is no stall
        _run(gate)
    watch.assert_called_once_with(gate.root, reporter)
    assert _gatelock._errors is _errors


def test_gate_skips_the_watch_without_a_reporter() -> None:
    """A gate built outside the CLI (tests, imports) never starts a watch."""
    with patch.object(_errors, "watch_stalls") as watch, fake_tk():
        _run(MealGate(demo_mode=True))
    watch.assert_not_called()
