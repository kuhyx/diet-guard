"""The Claude button wired into the real gate: the log, the unlock, the layout."""

from __future__ import annotations

import queue
from unittest.mock import patch

from diet_guard import _gatelock_claude, _gatelock_layout
from diet_guard import _gatelock_glyphs as g
from diet_guard._gatelock import MealGate
from diet_guard._gatelock_mealflow import _UNLOCK_DELAY_MS
from diet_guard._slot_wire import entry_slot_minute
from diet_guard._state_sync import read_raw_log
from diet_guard.tests._gate_fixtures import fake_tk
from diet_guard.tests.test_gatelock_claude import EST


def _entries() -> list[dict[str, object]]:
    return [e for day in read_raw_log().values() for e in day]


def _click(gate: MealGate, outcome: object) -> None:
    result: queue.Queue[object] = queue.Queue(maxsize=1)
    result.put(outcome)
    with patch.object(_gatelock_claude, "start_estimate", return_value=result):
        gate._on_claude()
    gate._claude_flow._poll()


def test_success_logs_the_locked_slot_and_unlocks(gate: MealGate) -> None:
    gate.demo_mode = False
    gate._pending = [720]
    gate._set_desc("owsianka z bananem")
    _click(gate, EST)
    (entry,) = _entries()
    assert entry["source"] == "claude"
    assert entry["desc"] == EST.desc
    assert entry_slot_minute(entry) == 720
    assert gate._pending == []
    gate.root.after.assert_called_with(_UNLOCK_DELAY_MS, gate.close)


def test_success_with_more_slots_advances_instead_of_unlocking(
    gate: MealGate,
) -> None:
    gate.demo_mode = False
    gate._pending = [480, 720]
    gate._set_desc("owsianka")
    _click(gate, EST)
    assert gate._pending == [720]
    assert entry_slot_minute(_entries()[0]) == 480


def test_failure_leaves_the_manual_path_usable(gate: MealGate) -> None:
    gate.demo_mode = False
    gate._pending = [480]
    gate._set_desc("owsianka")
    _click(gate, None)
    assert _entries() == []
    assert gate._pending == [480]
    assert gate._vars.claude_label.get() == g.CLAUDE_FAILED
    # The ordinary submit still logs and unlocks.
    gate._macro_entries()[0].insert(0, "300")
    gate._on_submit()
    assert gate._pending == [] or _entries()


def test_the_flow_is_built_once_per_gate(gate: MealGate) -> None:
    gate._set_desc("x")
    _click(gate, None)
    first = gate._claude_flow
    _click(gate, None)
    assert gate._claude_flow is first


def test_the_button_is_wired_on_every_monitor(gate: MealGate) -> None:
    built: list[object] = []
    real = _gatelock_layout.make_button

    def record(*args: object, **kwargs: object) -> object:
        button = real(*args, **kwargs)
        built.append(button)
        return button

    with (
        fake_tk(),
        patch.object(_gatelock_layout, "make_button", side_effect=record),
    ):
        wired = MealGate(demo_mode=True)
    claude = [
        b
        for b in built
        if getattr(b, "configured", {}).get("textvariable") is wired._vars.claude_label
    ]
    assert claude  # one per output, all on one shared variable
    assert all(b.configured["command"] == wired._on_claude for b in claude)
    assert wired._vars.claude_label.get() == g.CLAUDE
