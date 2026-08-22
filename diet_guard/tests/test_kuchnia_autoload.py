"""Tests for the gate's automatic catering fetch (trigger b).

Split from ``test_kuchnia_gate.py`` for the repo's 250-line cap; the button,
worker and field-formatting tests live there.

The property that matters: an *automatic* fetch stays quiet about bad news. The
gate has just told the user which slots to fill, and a caterer problem they
never asked about must not talk over that.
"""

from __future__ import annotations

import queue
from unittest.mock import patch

from diet_guard import _gatelock_delivery
from diet_guard._gatelock_kuchnia import DeliveryResult
from diet_guard.tests.test_kuchnia_gate import _deliver, _dish, _Gate


class TestAutoload:
    """Trigger (b): the window opening fetches the day's delivery itself."""

    def test_the_window_opening_starts_a_guarded_fetch(self) -> None:
        gate = _Gate()
        with patch.object(_gatelock_delivery, "start_delivery_fetch") as start:
            start.return_value = queue.Queue(maxsize=1)
            gate._autoload_delivery()
        assert start.call_count == 1
        # The guarded wrapper, not the raw refresh: several locks in one day
        # must not each pay for a login plus a three-request walk.
        assert start.call_args[0][0] is _gatelock_delivery.refresh_delivery_once

    def test_demo_mode_does_not_autoload(self) -> None:
        gate = _Gate()
        gate.demo_mode = True
        with patch.object(_gatelock_delivery, "start_delivery_fetch") as start:
            gate._autoload_delivery()
        assert start.call_count == 0

    def test_it_does_not_stack_on_a_running_fetch(self) -> None:
        gate = _Gate()
        gate._delivery_result = queue.Queue(maxsize=1)
        with patch.object(_gatelock_delivery, "start_delivery_fetch") as start:
            gate._autoload_delivery()
        assert start.call_count == 0

    def test_an_automatic_outage_is_silent(self) -> None:
        # The gate has just told the user which slots to fill; a caterer
        # problem they never asked about must not talk over that.
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(), reason="panel down"), asked=False)
        assert gate.statuses == []

    def test_an_automatic_empty_day_is_silent(self) -> None:
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(), reason=None), asked=False)
        assert gate.statuses == []

    def test_an_automatic_fetch_still_offers_the_dishes(self) -> None:
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(_dish(),), reason=None), asked=False)
        assert gate._descs == ["Kaszotto"]

    def test_the_button_still_reports_both(self) -> None:
        gate = _Gate()
        _deliver(gate, DeliveryResult(dishes=(), reason="panel down"), asked=True)
        assert "panel down" in gate.last_status
