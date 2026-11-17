"""The gate's Claude button: off-thread estimate, icon states, never a trap.

Driven without a real thread where it can be: the worker's queue is handed in
and the poll is called by hand, as in ``test_gatelock_fillall``. The rules:

* the Tk thread only polls a queue (the estimate runs on a daemon thread);
* a failure, a timeout, a late or stale result leaves the lock exactly as it
  was -- the manual log path never depends on this flow;
* a success logs through the gate's own ``record`` hook (``source="claude"``).
"""

from __future__ import annotations

import queue
import time
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from diet_guard import _gatelock_claude
from diet_guard import _gatelock_glyphs as g
from diet_guard._claude_estimate import EstimateError
from diet_guard._claude_schema import Estimate
from diet_guard._gatelock_claude import (
    CLAUDE_TIMEOUT_S,
    ClaudeFlow,
    ClaudeHooks,
    start_estimate,
)
from diet_guard.tests._claude_redirects import RealIoBlockedError

EST = Estimate("Owsianka z bananem", 320.0, 410.0, 15.0, 70.0, 8.0)


class Var:
    """The two StringVar methods the flow touches."""

    def __init__(self) -> None:
        self.value = g.CLAUDE

    def get(self) -> str:
        return self.value

    def set(self, value: str) -> None:
        self.value = value


class Harness:
    """A flow wired to recording hooks."""

    def __init__(self, text: str = "owsianka", slot: int | None = 480) -> None:
        self.root = MagicMock()
        self.label = Var()
        self.slot = slot
        self.record = MagicMock()
        self.status = MagicMock()
        hooks = ClaudeHooks(lambda: text, self.status, lambda: self.slot, self.record)
        self.flow = ClaudeFlow(self.root, self.label, hooks)

    def click_with(self, outcome: Estimate | None) -> queue.Queue[Estimate | None]:
        """Click with a worker whose result is already on the queue."""
        result: queue.Queue[Estimate | None] = queue.Queue(maxsize=1)
        result.put(outcome)
        with patch.object(_gatelock_claude, "start_estimate", return_value=result):
            self.flow.click()
        return result


class TestClick:
    """What a click does before any result exists."""

    def test_empty_description_never_calls_claude(self) -> None:
        h = Harness(text="")
        with patch.object(_gatelock_claude, "start_estimate") as start:
            h.flow.click()
        start.assert_not_called()
        assert h.status.call_args.kwargs == {"error": True}
        assert h.label.get() == g.CLAUDE

    def test_working_shows_the_spinner_and_polls(self) -> None:
        h = Harness()
        h.click_with(EST)
        assert h.label.get() in g.CLAUDE_BUSY
        h.root.after.assert_called_once()

    def test_a_second_click_while_working_is_ignored(self) -> None:
        h = Harness()
        h.click_with(EST)
        with patch.object(_gatelock_claude, "start_estimate") as start:
            h.flow.click()
        start.assert_not_called()


class TestPoll:
    """What the poll does with each outcome."""

    def test_success_logs_with_source_claude(self) -> None:
        h = Harness()
        h.click_with(EST)
        h.flow._poll()
        (desc, nutrition), _ = h.record.call_args
        assert desc == EST.desc
        assert (nutrition.kcal, nutrition.grams, nutrition.source) == (
            410.0,
            320.0,
            "claude",
        )
        assert h.label.get() == g.CLAUDE

    def test_pending_result_keeps_polling(self) -> None:
        h = Harness()
        with patch.object(_gatelock_claude, "start_estimate") as start:
            start.return_value = queue.Queue(maxsize=1)
            h.flow.click()
        h.root.after.reset_mock()
        h.flow._poll()
        h.root.after.assert_called_once()
        h.record.assert_not_called()

    def test_failure_shows_the_error_icon_and_logs_nothing(self) -> None:
        h = Harness()
        h.click_with(None)
        h.flow._poll()
        assert h.label.get() == g.CLAUDE_FAILED
        h.record.assert_not_called()

    def test_failure_leaves_the_flow_usable(self) -> None:
        h = Harness()
        h.click_with(None)
        h.flow._poll()
        h.click_with(EST)
        h.flow._poll()
        h.record.assert_called_once()

    def test_timeout_fails_even_without_a_result(self) -> None:
        h = Harness()
        start = time.monotonic()
        with (
            patch.object(_gatelock_claude, "monotonic", return_value=start),
            patch.object(_gatelock_claude, "start_estimate") as worker,
        ):
            worker.return_value = queue.Queue(maxsize=1)
            h.flow.click()
        late = start + CLAUDE_TIMEOUT_S + 1
        with patch.object(_gatelock_claude, "monotonic", return_value=late):
            h.flow._poll()
        assert h.label.get() == g.CLAUDE_FAILED
        h.record.assert_not_called()

    def test_hard_timeout_is_at_most_45_seconds(self) -> None:
        assert CLAUDE_TIMEOUT_S <= 45.0

    def test_result_for_a_slot_already_advanced_is_dropped(self) -> None:
        """The user logged the slot by hand while Claude was thinking."""
        h = Harness(slot=480)
        h.click_with(EST)
        h.slot = 720
        h.flow._poll()
        h.record.assert_not_called()
        assert h.label.get() == g.CLAUDE

    def test_a_record_error_still_resets_the_button(self) -> None:
        h = Harness()
        h.record.side_effect = OSError("disk")
        h.click_with(EST)
        with pytest.raises(OSError, match="disk"):
            h.flow._poll()
        assert h.label.get() == g.CLAUDE
        h.click_with(EST)  # not stuck "in flight"

    def test_a_stray_poll_after_completion_does_nothing(self) -> None:
        h = Harness()
        h.flow._poll()
        h.root.after.assert_not_called()
        h.record.assert_not_called()


class TestWorker:
    """The real thread, with a fake estimator."""

    def test_returns_the_estimate(self) -> None:
        with patch.object(_gatelock_claude, "estimate_meal", return_value=EST) as fn:
            result = start_estimate("owsianka")
            assert result.get(timeout=2) == EST
        fn.assert_called_once_with("owsianka", None)  # text only, no photo

    @pytest.mark.parametrize(
        "error", [EstimateError("estimate_failed", "x"), ValueError("y"), OSError("z")]
    )
    def test_any_failure_is_none_never_a_hang(self, error: Exception) -> None:
        with patch.object(_gatelock_claude, "estimate_meal", side_effect=error):
            assert start_estimate("owsianka").get(timeout=2) is None

    def test_the_default_seam_fails_closed(self) -> None:
        """conftest blocks the estimator: a test reaching it cannot spend quota."""
        estimate: Any = _gatelock_claude.estimate_meal
        with pytest.raises(RealIoBlockedError):
            estimate("x", None)
        assert start_estimate("x").get(timeout=2) is None

    def test_the_estimator_import_is_lazy(self) -> None:
        assert not hasattr(_gatelock_claude, "nonsense")
