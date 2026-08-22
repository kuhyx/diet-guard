"""Tests for the lock screen's catering button and its off-thread worker.

Two properties matter more than the rest, because breaking either strands a
user behind a fullscreen lock:

* the worker **always** feeds its queue, even when the call raises, or the poll
  waits forever with the button disabled;
* the flow **fails closed** -- an outage leaves the lock exactly as it was.

The completion path is driven directly (put a result, call the poll) rather
than through a thread, mirroring the doctrine in
:mod:`diet_guard._gatelock_fetch`: the worker touches no widget, so the Tk side
is testable with no thread at all.
"""

from __future__ import annotations

import datetime
import queue
from types import SimpleNamespace
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

from diet_guard import _gatelock_delivery
from diet_guard._gatelock_delivery import _PullFlows, dish_field_values
from diet_guard._gatelock_kuchnia import (
    UNEXPECTED,
    DeliveryResult,
    start_delivery_fetch,
)
from diet_guard._kuchnia_parse import Dish

if TYPE_CHECKING:
    from collections.abc import Sequence

DAY = datetime.date(2026, 8, 22)


def _dish(name: str = "Kaszotto", priority: int = 1) -> Dish:
    return Dish(
        name=name,
        kcal=391.0,
        protein_g=32.5,
        carbs_g=35.6,
        fat_g=13.0,
        grams=318.0,
        priority=priority,
        slot_label="Kolacja",
    )


class TestWorker:
    def test_hands_back_the_dishes(self) -> None:
        result = start_delivery_fetch(lambda _day: ([_dish()], None), DAY)
        outcome = result.get(timeout=5)
        assert outcome.reason is None
        assert outcome.dishes[0].name == "Kaszotto"

    def test_hands_back_a_reason(self) -> None:
        result = start_delivery_fetch(lambda _day: ([], "panel down"), DAY)
        assert result.get(timeout=5).reason == "panel down"

    def test_a_raising_call_still_feeds_the_queue(self) -> None:
        # Without the finally, the poll waits forever with the button disabled
        # and the user cannot get out from behind the lock.
        def boom(_day: datetime.date) -> tuple[Sequence[Dish], str | None]:
            msg = "kaboom"
            raise RuntimeError(msg)

        result = start_delivery_fetch(boom, DAY)
        assert result.get(timeout=5).reason == UNEXPECTED


class _Gate(_PullFlows):
    """The slice of the controller the catering flow drives."""

    def __init__(self) -> None:
        self.root = MagicMock()
        self.demo_mode = False
        self.statuses: list[tuple[str, bool]] = []
        self._widgets = SimpleNamespace(amount_entry=MagicMock())
        self._state = SimpleNamespace(source="manual")
        self._descs: list[str] = []
        self._cleared = 0
        self._projections = 0
        self._entries = [MagicMock() for _ in range(4)]

    def _set_status(self, text: str, *, error: bool = False) -> None:
        self.statuses.append((text, error))

    def _set_desc(self, value: str) -> None:
        self._descs.append(value)

    def _clear_inputs(self) -> None:
        self._cleared += 1

    def _refresh_projection(self) -> None:
        self._projections += 1

    def _macro_entries(self) -> tuple[MagicMock, ...]:
        return tuple(self._entries)

    @property
    def last_status(self) -> str:
        return self.statuses[-1][0]


def _deliver(gate: _Gate, outcome: DeliveryResult, *, asked: bool = True) -> None:
    """Hand the gate a completed result and run its poll, with no thread.

    ``asked`` mirrors whether the fetch came from the button (the default) or
    from the window opening; an automatic one stays quiet about bad news.
    """
    gate._delivery_asked = asked
    result: queue.Queue[DeliveryResult] = queue.Queue(maxsize=1)
    result.put(outcome)
    gate._delivery_result = result
    gate._poll_delivery()


class TestLoadButton:
    def test_demo_mode_refuses(self) -> None:
        # A synthetic window must never satisfy a real checkpoint, and there is
        # no reason to send real credentials from one.
        gate = _Gate()
        gate.demo_mode = True
        gate._on_load_delivery()
        assert "only available on the real lock" in gate.last_status
        assert gate._delivery_result is None

    def test_a_second_click_while_in_flight_is_ignored(self) -> None:
        gate = _Gate()
        with patch.object(_gatelock_delivery, "start_delivery_fetch") as start:
            start.return_value = queue.Queue(maxsize=1)
            gate._on_load_delivery()
            gate._on_load_delivery()
        assert start.call_count == 1

    def test_an_outage_leaves_the_lock_untouched(self) -> None:
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(), reason="panel down"))
        text, error = gate.statuses[-1]
        assert "panel down" in text
        assert "still locked" in text
        assert error is True
        assert gate._descs == []

    def test_no_delivery_today_says_so(self) -> None:
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(), reason=None))
        assert "No catering delivery today" in gate.last_status

    def test_a_dish_is_offered_but_never_logged(self) -> None:
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(_dish(),), reason=None))
        # The form is filled...
        assert gate._descs == ["Kaszotto"]
        gate._widgets.amount_entry.insert.assert_called_once_with(0, "318")
        # ...and that is all. Submitting stays the user's explicit action.
        assert "Log & Continue" in gate.last_status

    def test_dishes_are_offered_one_at_a_time_in_meal_order(self) -> None:
        gate = _Gate()
        dishes = (_dish("Kolacja", priority=2), _dish("Sniadanie", priority=1))
        _deliver(gate, DeliveryResult(dishes=dishes, reason=None))
        assert gate._descs == ["Sniadanie"]
        assert "1 more to go" in gate.last_status
        gate._prefill_next_dish()
        assert gate._descs == ["Sniadanie", "Kolacja"]

    def test_the_last_dish_has_no_more_to_go_suffix(self) -> None:
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(_dish(),), reason=None))
        assert "more to go" not in gate.last_status

    def test_prefilling_past_the_end_is_a_no_op(self) -> None:
        gate = _Gate()
        gate._prefill_next_dish()
        assert gate._descs == []

    def test_the_poll_rearms_while_the_worker_runs(self) -> None:
        gate = _Gate()
        gate._delivery_result = queue.Queue(maxsize=1)
        gate._poll_delivery()
        gate.root.after.assert_called_with(
            _gatelock_delivery.FETCH_POLL_MS,
            gate._poll_delivery,
        )
        assert gate._delivery_result is not None

    def test_a_stray_poll_after_completion_stops(self) -> None:
        gate = _Gate()
        gate._delivery_result = None
        gate._poll_delivery()
        assert gate.statuses == []
        gate.root.after.assert_not_called()


class TestFieldFormatting:
    def test_values_are_trimmed_not_padded(self) -> None:
        grams, macros = dish_field_values(_dish())
        assert grams == "318"
        assert macros == ("391", "32.5", "35.6", "13")

    def test_the_macro_order_matches_the_form(self) -> None:
        # _macro_entries() is (kcal, protein, carbs, fat); a mismatch here
        # would silently swap a dish's protein and carbohydrate.
        _grams, macros = dish_field_values(
            Dish("x", 100.0, 1.0, 2.0, 3.0, 50.0, 1, ""),
        )
        assert macros == ("100", "1", "2", "3")


def test_unknown_lazy_attribute_raises() -> None:
    # The name lives in a variable so ruff cannot fold the lookup into a
    # bare attribute access and then flag it as a useless expression.
    missing = "not_a_real_helper"
    with pytest.raises(AttributeError, match="no attribute"):
        getattr(_gatelock_delivery, missing)
