"""The open gate window pulls peer logs on its own every ~30 s.

2026-11-16: the credit watch only fires on a *local* write, and nothing on the PC
wrote while the window was up, so a meal logged on the phone waited for the user
to press Fetch. ``arm_peer_pull`` runs the Fetch button's own narrow pull
(``pull_peer_logs``) on a timer; the write it makes trips the watch, which owns
the close. So this path is silent and never unlocks anything itself.
"""

from __future__ import annotations

import logging
import queue
from types import SimpleNamespace
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

from diet_guard import _gatelock_peerpull
from diet_guard._gatelock_fetch import FETCH_POLL_MS
from diet_guard._gatelock_peerpull import PEER_PULL_MS, arm_peer_pull

if TYPE_CHECKING:
    import pytest


def _host() -> SimpleNamespace:
    """A stand-in gate: a recording Tk root and the shared in-flight slot."""
    root = MagicMock()
    return SimpleNamespace(
        root=root, fetch_result=None, _reconcile_after_fetch=MagicMock()
    )


def _fire(host: SimpleNamespace) -> None:
    """Run the callback most recently handed to ``root.after``."""
    host.root.after.call_args.args[1]()


class TestTick:
    """What one interval does."""

    def test_arms_the_first_pull_one_interval_out(self) -> None:
        host = _host()
        arm_peer_pull(host)
        assert host.root.after.call_args.args[0] == PEER_PULL_MS == 30_000

    def test_an_idle_tick_starts_the_narrow_pull_off_thread(self) -> None:
        host, result = _host(), queue.Queue[str | None](maxsize=1)
        with patch.object(
            _gatelock_peerpull, "start_fetch", return_value=result
        ) as start:
            arm_peer_pull(host)
            _fire(host)
        start.assert_called_once_with(_gatelock_peerpull.pull_peer_logs)
        assert host.fetch_result is result
        assert host.root.after.call_args.args[0] == FETCH_POLL_MS

    def test_a_tick_during_a_button_fetch_starts_nothing(self) -> None:
        """One in-flight pull for both writers: the Fetch button's slot counts."""
        host = _host()
        host.fetch_result = busy = queue.Queue[str | None](maxsize=1)
        with patch.object(_gatelock_peerpull, "start_fetch") as start:
            arm_peer_pull(host)
            _fire(host)
        start.assert_not_called()
        assert host.fetch_result is busy
        assert host.root.after.call_args.args[0] == PEER_PULL_MS

    def test_the_poll_waits_while_the_worker_runs(self) -> None:
        host, result = _host(), queue.Queue[str | None](maxsize=1)
        with patch.object(_gatelock_peerpull, "start_fetch", return_value=result):
            arm_peer_pull(host)
            _fire(host)
            _fire(host)  # worker still running: nothing on the queue
        assert host.fetch_result is result
        assert host.root.after.call_args.args[0] == FETCH_POLL_MS


class TestCompletion:
    """What a finished pull does -- and, above all, does not do."""

    def _finish(self, reason: str | None) -> tuple[SimpleNamespace, int]:
        host, result = _host(), queue.Queue[str | None](maxsize=1)
        with patch.object(_gatelock_peerpull, "start_fetch", return_value=result):
            arm_peer_pull(host)
            _fire(host)
            result.put(reason)
            _fire(host)
        return host, host.root.after.call_count

    def test_success_is_silent_frees_the_slot_and_rearms(self) -> None:
        host, _ = self._finish(None)
        assert host.fetch_result is None
        assert host.root.after.call_args.args[0] == PEER_PULL_MS
        host._reconcile_after_fetch.assert_not_called()  # the watch owns the close

    def test_a_failure_is_logged_retried_and_never_unlocks(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        with caplog.at_level(logging.WARNING, logger=_gatelock_peerpull.__name__):
            host, _ = self._finish("sync unavailable (boom)")
        assert "sync unavailable (boom)" in caplog.text
        assert host.fetch_result is None
        assert host.root.after.call_args.args[0] == PEER_PULL_MS
        host._reconcile_after_fetch.assert_not_called()

    def test_a_stray_poll_with_no_slot_does_nothing(self) -> None:
        host = _host()
        arm_peer_pull(host)
        poll = _gatelock_peerpull._poll_closure(host, PEER_PULL_MS)
        before = host.root.after.call_count
        poll()
        assert host.root.after.call_count == before
