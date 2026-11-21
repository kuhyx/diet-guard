"""Tests for the off-thread food lookup of MealGate.

Covers :mod:`._gatelock_lookup` (``start_lookup``, ``LookupRunner``) and the
two ``_GateMealFlow`` methods that use it.  The functional fake ``tk`` widgets
and the ``gate`` fixture live in ``conftest.py``.
"""

from __future__ import annotations

import queue
import threading
import time
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

from diet_guard import _gatelock_glyphs as g
from diet_guard import _gatelock_lookup
from diet_guard._gatelock_fetch import FETCH_POLL_MS
from diet_guard._gatelock_lookup import LookupRunner, start_lookup
from diet_guard.tests.conftest import _nutrition

if TYPE_CHECKING:
    import pytest

    from diet_guard._estimator import Nutrition
    from diet_guard._gatelock import MealGate

    Candidates = list[tuple[str, Nutrition]]


def _failing_lookup(_desc: str) -> Candidates:
    msg = "bad payload"
    raise ValueError(msg)


class TestStartLookup:
    """The worker thread always feeds its queue."""

    def test_puts_result(self) -> None:
        """A finished lookup's candidates land on the queue."""
        found = [("apple", _nutrition(95, 100))]
        assert start_lookup(lambda _d: found, "apple").get(timeout=5) == found

    def test_failure_puts_empty_and_logs(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """A failing lookup is logged and still answers, with no candidates."""
        with caplog.at_level("ERROR"):
            assert start_lookup(_failing_lookup, "x").get(timeout=5) == []
        assert any("food lookup failed" in r.message for r in caplog.records)


class TestLookupRunner:
    """One lookup at a time, collected by a Tk-side poll."""

    def test_start_schedules_poll(self) -> None:
        """Starting a lookup schedules the poll and reports it started."""
        root = MagicMock()
        runner = LookupRunner(root, MagicMock(), lambda: "apple")
        with patch.object(_gatelock_lookup, "start_lookup", return_value=queue.Queue()):
            assert runner.start("apple") is True
        root.after.assert_called_once_with(FETCH_POLL_MS, runner.poll)

    def test_second_start_while_running_is_ignored(self) -> None:
        """A second submit during a lookup starts nothing."""
        runner = LookupRunner(MagicMock(), MagicMock(), lambda: "slow")
        with patch.object(
            _gatelock_lookup, "start_lookup", return_value=queue.Queue()
        ) as start:
            runner.start("first")
            assert runner.start("second") is False
        start.assert_called_once()

    def test_poll_reschedules_until_done(self) -> None:
        """An empty queue polls again; a result goes to the handler once."""
        root, on_result = MagicMock(), MagicMock()
        runner = LookupRunner(root, on_result, lambda: "apple")
        pending: queue.Queue[Candidates] = queue.Queue()
        with patch.object(_gatelock_lookup, "start_lookup", return_value=pending):
            runner.start("apple")
        runner.poll()
        assert root.after.call_count == 2
        on_result.assert_not_called()
        pending.put([])
        runner.poll()
        on_result.assert_called_once_with([])
        runner.poll()  # nothing in flight any more: a stray poll is a no-op
        assert root.after.call_count == 2
        on_result.assert_called_once()

    def test_start_does_not_wait_for_the_lookup(self) -> None:
        """The Tk thread returns at once while the lookup is still running."""
        release = threading.Event()

        def slow_lookup(desc: str) -> Candidates:
            release.wait(5)
            return [(desc, _nutrition())]

        runner = LookupRunner(MagicMock(), MagicMock(), lambda: "slow")
        began = time.perf_counter()
        with patch.object(_gatelock_lookup, "lookup_candidates", slow_lookup):
            runner.start("slow")
        assert time.perf_counter() - began < 0.1
        result = runner._result
        assert result is not None
        assert result.empty()
        release.set()
        assert result.get(timeout=5)[0][0] == "slow"


class TestGateLookup:
    """Step one of a submit: the gate fills the form from a lookup."""

    def _lookup(self, gate: MealGate, found: Candidates) -> None:
        """Run ``_begin_lookup`` with a ready result, then collect it."""
        ready: queue.Queue[Candidates] = queue.Queue()
        ready.put(found)
        gate._set_desc("apple")
        with patch.object(_gatelock_lookup, "start_lookup", return_value=ready):
            gate._begin_lookup("apple")
        assert gate._vars.status.get() == g.BUSY
        assert gate._lookup is not None
        gate._lookup.poll()

    def test_no_candidates(self, gate: MealGate) -> None:
        """No match asks for a manual value."""
        self._lookup(gate, [])
        assert gate._vars.status.get().startswith(g.ERROR)

    def test_single_candidate(self, gate: MealGate) -> None:
        """A single match fills the fields and invites review."""
        self._lookup(gate, [("apple", _nutrition(95, 100))])
        assert gate._vars.status.get().startswith(g.OK)
        assert g.TIMES not in gate._vars.status.get()

    def test_multiple_candidates(self, gate: MealGate) -> None:
        """Several matches invite picking another."""
        self._lookup(gate, [("a", _nutrition(95, 100)), ("b", _nutrition(120, 100))])
        assert gate._vars.status.get().endswith(f"  {g.TIMES}2")

    def test_second_submit_keeps_busy_status(self, gate: MealGate) -> None:
        """A submit during a lookup neither restarts it nor touches the status."""
        with patch.object(_gatelock_lookup, "start_lookup", return_value=queue.Queue()):
            gate._begin_lookup("apple")
            gate._set_status("other")
            gate._begin_lookup("apple")
        assert gate._vars.status.get() == "other"

    def test_result_for_a_food_no_longer_typed_is_dropped(self, gate: MealGate) -> None:
        """A late result never fills the form for whatever the user moved on to."""
        pending: queue.Queue[Candidates] = queue.Queue()
        gate._set_desc("apple")
        with patch.object(_gatelock_lookup, "start_lookup", return_value=pending):
            gate._begin_lookup("apple")
        gate._clear_inputs()  # the meal was logged by hand; the form moved on
        pending.put([("apple", _nutrition(95, 100))])
        assert gate._lookup is not None
        gate._lookup.poll()
        assert gate._widgets.macros.kcal.get() == ""
        assert gate._get_desc() == ""
