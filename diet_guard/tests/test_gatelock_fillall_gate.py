""" "Fill all" wired into the real gate: the button, the unlock, the leftovers.

:mod:`test_gatelock_fillall` drives the flow alone; this pins what the gate
adds around it -- one flow per gate, an unlock that names catering as its
reason, a button that relabels on every monitor, and an unlock line that does
not claim already-logged dishes are still waiting.
"""

from __future__ import annotations

from datetime import timedelta
import os
import queue
import tkinter as tk
from tkinter import ttk
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

from diet_guard import _gatelock_delivery, _gatelock_fillall, _gatelock_layout
from diet_guard._gatelock import MealGate
from diet_guard._gatelock_fillall import FILL_LABEL, _refresh_delivery
from diet_guard._gatelock_layout import build_layout
from diet_guard._gatelock_mealflow import _UNLOCK_DELAY_MS
from diet_guard._gatelock_ui import GateCallbacks, make_vars
from diet_guard._state import log_meal, now_local
from diet_guard._state_today import logged_slots_today
from diet_guard.tests._gate_fixtures import fake_tk
from diet_guard.tests.conftest import _nutrition
from diet_guard.tests.test_gatelock_fillall import (
    FOUR,
    Harness,
    delivered,
    dish,
    fetching,
    logged,
)

if TYPE_CHECKING:
    from collections.abc import Callable, Iterator

    from gatelock import ButtonStyle, LockConfig
    from pytest_xvfb import Xvfb

    from diet_guard._gatelock_kuchnia import DeliveryResult


def _due_from_log(pending: list[int]) -> Callable[[], tuple[int, ...]]:
    """``due_slots`` as the log on disk says, so an unlock needs a real write."""

    def due() -> tuple[int, ...]:
        taken = logged_slots_today()
        return tuple(slot for slot in pending if slot not in taken)

    return due


def _fill(gate: MealGate, outcome: DeliveryResult) -> None:
    """Click "Fill all", let the poll propose, then click again to confirm."""
    result: queue.Queue[DeliveryResult] = queue.Queue(maxsize=1)
    result.put(outcome)
    with patch.object(_gatelock_fillall, "start_delivery_fetch", return_value=result):
        gate._on_fill_all()
    flow = gate._fill_flow
    assert flow is not None
    flow._poll()
    gate._on_fill_all()
    assert gate._fill_flow is flow  # built once, then reused


def test_the_fetch_imports_the_http_stack_lazily() -> None:
    day = now_local().date()
    target = "diet_guard._kuchnia_import.refresh_delivery"
    with patch(target, return_value=(FOUR, None)) as refresh:
        assert _refresh_delivery(day) == (FOUR, None)
    refresh.assert_called_once_with(day)


class TestTheGateDrivesTheFlow:
    def test_a_demo_gate_refuses(self, gate: MealGate) -> None:
        with patch.object(_gatelock_fillall, "start_delivery_fetch") as start:
            gate._on_fill_all()
        start.assert_not_called()
        assert "only available on the real lock" in gate._vars.status.get()

    def test_fill_and_confirm_unlocks_from_catering(self, gate: MealGate) -> None:
        gate.demo_mode = False  # read once, when the flow is first built
        gate._pending = [480, 720]
        # Fill all also banks the dishes for one-at-a-time offering; the
        # unlock line must not then call them "still delivered".
        gate._delivery_pending = FOUR
        due = _due_from_log([480, 720])
        with patch.object(_gatelock_delivery, "due_slots", side_effect=due):
            _fill(gate, delivered(*FOUR))
        status = gate._vars.status.get()
        assert status == "Filled from catering — all meals logged, unlocking…"
        assert gate._pending == []
        gate.root.after.assert_called_with(_UNLOCK_DELAY_MS, gate.close)
        assert sorted(logged()) == [480, 720, 960, 1200]
        assert gate._vars.fill_label.get() == FILL_LABEL

    def test_a_partial_fill_advances_instead_of_unlocking(self, gate: MealGate) -> None:
        gate.demo_mode = False
        gate._pending = [480, 720]
        due = _due_from_log([480, 720])
        # Two dishes spread onto 08:00 and 16:00: 12:00 is still owed.
        two = (dish("Owsianka", 1), dish("Obiad", 2))
        with patch.object(_gatelock_delivery, "due_slots", side_effect=due):
            _fill(gate, delivered(*two))
        assert gate._pending == [720]
        assert "Pulled 1 meal " in gate._vars.status.get()
        assert "unlocking" not in gate._vars.status.get()


class TestLeftoverDishesAtUnlock:
    """The "(N more dishes delivered)" suffix counts only unlogged dishes."""

    def test_an_already_logged_dish_is_not_leftover(self, gate: MealGate) -> None:
        # Case and padding differ from the dish name on purpose.
        log_meal("  KOLACJA ", _nutrition(), 20)
        gate._delivery_pending = (dish("Kolacja", 4), dish("Obiad", 3))
        gate._unlock("Logged 20:00")
        assert gate._vars.status.get() == (
            "Logged 20:00 (1 more dish delivered; log with 'ate') — "
            "all meals logged, unlocking…"
        )

    def test_unlogged_dishes_are_all_counted(self, gate: MealGate) -> None:
        gate._delivery_pending = (dish("Kolacja", 4), dish("Obiad", 3))
        gate._unlock("Logged 20:00")
        assert "(2 more dishes delivered;" in gate._vars.status.get()

    def test_every_queued_dish_logged_means_no_suffix(self, gate: MealGate) -> None:
        log_meal("Kolacja", _nutrition(), 20)
        gate._delivery_pending = (dish("Kolacja", 4),)
        gate._unlock("Logged 20:00")
        assert "more dish" not in gate._vars.status.get()


class TestTheButton:
    @pytest.mark.usefixtures("dual_output")
    def test_every_monitor_shares_one_label(self) -> None:
        built: list[tk.Button] = []
        real = _gatelock_layout.make_button

        def record(
            parent: tk.Misc,
            config: LockConfig,
            text: str,
            command: Callable[[], None],
            style: ButtonStyle | None = None,
        ) -> tk.Button:
            button = real(parent, config, text, command, style)
            built.append(button)
            return button

        with (
            fake_tk(),
            patch.object(_gatelock_layout, "make_button", side_effect=record),
        ):
            gate = MealGate(demo_mode=True)
        fills = [
            b
            for b in built
            if getattr(b, "configured", {}).get("textvariable") is gate._vars.fill_label
        ]
        assert len(fills) == 2  # one per monitor, one shared variable
        assert all(b.configured["command"] == gate._on_fill_all for b in fills)

    def test_the_real_button_relabels_through_its_variable(
        self, xvfb: Xvfb | None
    ) -> None:
        # Real Tk, so only ever on pytest-xvfb's private display -- never the
        # user's. No Xvfb means no test, not a window on :0.
        if xvfb is None:
            pytest.skip("needs pytest-xvfb's private display")
        assert os.environ["DISPLAY"] == f":{xvfb.display}"
        root = tk.Tk()
        try:
            root.withdraw()
            on_fill_all = MagicMock()
            callbacks = GateCallbacks(
                *(MagicMock() for _ in range(5)), on_fill_all=on_fill_all
            )
            vars_ = make_vars(root)
            notebook = ttk.Notebook(root)
            widgets = build_layout(notebook, vars_, callbacks, demo_mode=False)
            button = _find_fill_button(widgets.frame, str(vars_.fill_label))
            assert button.cget("text") == FILL_LABEL
            vars_.fill_label.set("✓ Confirm (3)")
            assert button.cget("text") == "✓ Confirm (3)"
            button.invoke()
            on_fill_all.assert_called_once_with()
        finally:
            root.destroy()


def _walk(widget: tk.Misc) -> Iterator[tk.Misc]:
    yield widget
    for child in widget.winfo_children():
        yield from _walk(child)


def _find_fill_button(frame: tk.Misc, var_name: str) -> tk.Button:
    matches = [
        w
        for w in _walk(frame)
        if isinstance(w, tk.Button) and str(w.cget("textvariable")) == var_name
    ]
    assert len(matches) == 1
    return matches[0]


def test_a_fetch_spanning_midnight_never_confirms_yesterdays_menu() -> None:
    # Clicked on day D; the result lands, and Confirm comes on D+1. The plan
    # belongs to the day that was *fetched*, so D+1 refetches and logs nothing.
    h = Harness()
    tomorrow = now_local() + timedelta(days=1)
    with fetching(delivered(*FOUR), delivered()) as start:
        h.flow.click()
        with patch.object(_gatelock_fillall, "now_local", return_value=tomorrow):
            h.flow._poll()
            h.flow.click()
    assert start.call_args.args[1] == tomorrow.date()
    assert logged() == {}
