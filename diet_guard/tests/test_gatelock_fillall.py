"""Tests for the lock screen's two-click "Fill all" catering flow.

The properties that matter, because the gate exists to stop unattended logging:

* the first click **never writes** -- it only proposes, and relabels the button;
* the second click writes only into slots that are **still empty right now**,
  so a meal typed between the two clicks keeps its slot;
* a proposal does not survive midnight.

Driven without threads, as in :mod:`test_kuchnia_gate`: the fetch hands back a
pre-filled queue and the poll is called directly.
"""

from __future__ import annotations

from datetime import timedelta
import queue
from typing import TYPE_CHECKING, cast
from unittest.mock import MagicMock, patch

from diet_guard import _gatelock_fillall
from diet_guard._gatelock_fetch import FETCH_POLL_MS
from diet_guard._gatelock_fillall import FILL_LABEL, FillAllFlow, FillHooks
from diet_guard._gatelock_kuchnia import DeliveryResult
from diet_guard._kuchnia_parse import Dish
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._slot_wire import entry_slot_minute
from diet_guard._slots import day_slots
from diet_guard._state import log_meal, now_local
from diet_guard._state_today import today_entries
from diet_guard.tests._tk_fakes import FakeVar
from diet_guard.tests.conftest import _nutrition

if TYPE_CHECKING:
    from collections.abc import Iterator
    from contextlib import AbstractContextManager
    import tkinter as tk


def dish(name: str, priority: int, kcal: float = 400.0) -> Dish:
    """A catering dish with its own name, meal order and calories."""
    return Dish(name, kcal, 30.0, 40.0, 10.0, 300.0, priority, "")


#: One dish per default slot, in the caterer's meal order.
FOUR = (
    dish("Owsianka", 1, 350),
    dish("Wrap", 2, 420.5),
    dish("Obiad", 3, 600),
    dish("Kolacja", 4, 194),
)


class Harness:
    """A flow plus everything it calls back into, recorded."""

    def __init__(self, *, demo_mode: bool = False) -> None:
        self.root = MagicMock()
        self.label = FakeVar(value=FILL_LABEL)
        self.statuses: list[tuple[str, bool]] = []
        self.on_logged = MagicMock()
        hooks = FillHooks(self._status, self.on_logged)
        label = cast("tk.StringVar", self.label)
        self.flow = FillAllFlow(self.root, label, hooks, demo_mode=demo_mode)

    def _status(self, text: str, *, error: bool = False) -> None:
        self.statuses.append((text, error))

    @property
    def status(self) -> str:
        return self.statuses[-1][0]


def fetching(*outcomes: DeliveryResult) -> AbstractContextManager[MagicMock]:
    """Patch the fetch so each click gets one pre-delivered result, in order."""

    def _results() -> Iterator[queue.Queue[DeliveryResult]]:
        for outcome in outcomes:
            result: queue.Queue[DeliveryResult] = queue.Queue(maxsize=1)
            result.put(outcome)
            yield result

    return patch.object(
        _gatelock_fillall, "start_delivery_fetch", side_effect=_results()
    )


def delivered(*dishes: Dish) -> DeliveryResult:
    return DeliveryResult(dishes=dishes, reason=None)


def logged() -> dict[int, list[str]]:
    """Today's on-disk log as recorded slot minute -> descriptions."""
    by_slot: dict[int, list[str]] = {}
    for entry in today_entries():
        slot = entry_slot_minute(entry) or 0
        by_slot.setdefault(slot, []).append(str(entry["desc"]))
    return by_slot


def propose(h: Harness) -> None:
    """The first click: fetch, then the poll that turns dishes into a plan."""
    h.flow.click()
    h.flow._poll()


def test_default_schedule_precondition() -> None:
    # Every expectation below assumes the redirected (default) schedule.
    assert day_slots(current_schedule()) == (480, 720, 960, 1200)


class TestFirstClick:
    def test_demo_mode_refuses_without_fetching(self) -> None:
        h = Harness(demo_mode=True)
        with fetching() as start:
            h.flow.click()
        start.assert_not_called()
        assert "only available on the real lock" in h.status
        assert h.label.get() == FILL_LABEL

    def test_a_click_while_fetching_is_ignored(self) -> None:
        h = Harness()
        with patch.object(_gatelock_fillall, "start_delivery_fetch") as start:
            start.return_value = queue.Queue(maxsize=1)
            h.flow.click()
            h.flow.click()
        start.assert_called_once_with(
            _gatelock_fillall._refresh_delivery, now_local().date()
        )
        assert h.statuses == [("Loading today's delivery…", False)]
        h.root.after.assert_called_once_with(FETCH_POLL_MS, h.flow._poll)

    def test_the_poll_rearms_while_the_worker_runs(self) -> None:
        h = Harness()
        with patch.object(_gatelock_fillall, "start_delivery_fetch") as start:
            start.return_value = queue.Queue(maxsize=1)
            h.flow.click()
        h.flow._poll()
        assert h.root.after.call_count == 2
        h.root.after.assert_called_with(FETCH_POLL_MS, h.flow._poll)

    def test_a_stray_poll_is_inert(self) -> None:
        h = Harness()
        h.flow._poll()
        assert h.statuses == []
        h.root.after.assert_not_called()

    def test_an_outage_proposes_nothing(self) -> None:
        h = Harness()
        with fetching(DeliveryResult(dishes=(), reason="panel down")):
            propose(h)
        assert h.statuses[-1] == ("panel down — still locked.", True)
        assert h.label.get() == FILL_LABEL
        # Fetch done: the next click may fetch again rather than being ignored.
        assert h.flow._result is None

    def test_no_delivery_today(self) -> None:
        h = Harness()
        with fetching(delivered()):
            propose(h)
        assert h.status == "No catering delivery today."
        assert h.label.get() == FILL_LABEL

    def test_every_slot_already_logged(self) -> None:
        for slot in (480, 720, 960, 1200):
            log_meal(f"mine {slot}", _nutrition(), slot)
        h = Harness()
        with fetching(delivered(*FOUR)):
            propose(h)
        assert h.status == "Every slot already has a meal — nothing to fill."
        assert h.label.get() == FILL_LABEL

    def test_the_proposal_writes_nothing(self) -> None:
        log_meal("my sandwich", _nutrition(), 720)
        h = Harness()
        with fetching(delivered(*FOUR)):
            propose(h)
        assert h.label.get() == "✓ Confirm (3)"
        assert h.status == (
            "Will log 3 (1144 kcal): 08:00 Owsianka, 16:00 Obiad, "
            "20:00 Kolacja — click Confirm."
        )
        assert logged() == {720: ["my sandwich"]}
        h.on_logged.assert_not_called()


class TestConfirm:
    def test_confirm_fills_only_the_empty_slots(self) -> None:
        log_meal("my sandwich", _nutrition(), 720)
        h = Harness()
        with fetching(delivered(*FOUR)) as start:
            propose(h)
            h.flow.click()
        assert start.call_count == 1  # the confirm did not refetch
        assert logged() == {
            480: ["Owsianka"],
            720: ["my sandwich"],
            960: ["Obiad"],
            1200: ["Kolacja"],
        }
        assert h.status == "Logged 3 catering dish(es)."
        h.on_logged.assert_called_once_with()
        assert h.label.get() == FILL_LABEL

    def test_two_dishes_spread_into_one_empty_slot_both_land(self) -> None:
        # 5 dishes on 4 slots: the spread doubles up 08:00.
        h = Harness()
        five = (*FOUR, dish("Przekaska", 5, 100))
        with fetching(delivered(*five)):
            propose(h)
            h.flow.click()
        assert logged()[480] == ["Owsianka", "Wrap"]
        assert h.status == "Logged 5 catering dish(es)."

    def test_a_meal_typed_between_the_clicks_keeps_its_slot(self) -> None:
        h = Harness()
        with fetching(delivered(*FOUR)):
            propose(h)
        assert h.label.get() == "✓ Confirm (4)"
        log_meal("toast", _nutrition(), 480)
        h.flow.click()
        assert logged()[480] == ["toast"]
        assert h.status == "Logged 3 catering dish(es)."

    def test_every_slot_taken_between_the_clicks(self) -> None:
        h = Harness()
        with fetching(delivered(*FOUR)):
            propose(h)
        for slot in (480, 720, 960, 1200):
            log_meal(f"mine {slot}", _nutrition(), slot)
        h.flow.click()
        assert h.status == "Every slot already has a meal — nothing to fill."
        h.on_logged.assert_not_called()
        assert h.label.get() == FILL_LABEL
        assert all(descs == [f"mine {s}"] for s, descs in logged().items())

    def test_a_proposal_from_yesterday_is_refetched(self) -> None:
        h = Harness()
        tomorrow = now_local() + timedelta(days=1)
        with fetching(delivered(*FOUR), delivered()) as start:
            propose(h)
            with patch.object(_gatelock_fillall, "now_local", return_value=tomorrow):
                h.flow.click()
        assert start.call_count == 2
        refetch = (_gatelock_fillall._refresh_delivery, tomorrow.date())
        assert start.call_args.args == refetch
        assert logged() == {}
        h.on_logged.assert_not_called()
        assert h.label.get() == FILL_LABEL
        assert h.status == "Loading today's delivery…"
