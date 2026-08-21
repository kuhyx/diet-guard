"""Tests for the event-driven post-log sync trigger.

These exercise the real :func:`publish_after_log`, not the conftest stub: the
autouse fixture patches it at each *call site*, so importing it here still
reaches the genuine helper (see ``conftest._isolate_state``).
"""

from __future__ import annotations

import logging
import threading
from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _sync_events
from diet_guard._sync_events import publish_after_log

if TYPE_CHECKING:
    import pytest


class TestPublishAfterLog:
    """A full tick fired by a local write, which must never raise."""

    def test_success_returns_none(self) -> None:
        """A completed tick reports no reason."""
        with patch.object(
            _sync_events,
            "pull_shared_log",
            return_value=None,
        ) as pull:
            assert publish_after_log() is None
        pull.assert_called_once_with()

    def test_outage_returns_reason(self) -> None:
        """A failed tick surfaces the reason instead of raising."""
        with patch.object(
            _sync_events,
            "pull_shared_log",
            return_value="sync unavailable (no token)",
        ):
            assert publish_after_log() == "sync unavailable (no token)"

    def test_outage_is_logged(self, caplog: pytest.LogCaptureFixture) -> None:
        """The reason reaches the log for callers with nowhere to show it."""
        with (
            patch.object(
                _sync_events,
                "pull_shared_log",
                return_value="sync unavailable (boom)",
            ),
            caplog.at_level(logging.INFO, logger="diet_guard._sync_events"),
        ):
            publish_after_log()
        assert "boom" in caplog.text


class TestPublishAfterLogDetached:
    """The CLI's non-blocking publish."""

    def test_runs_the_publish_off_thread(self) -> None:
        """The caller must not wait ~15.5s for the tick to finish."""
        done = threading.Event()

        def _publish() -> None:
            done.set()

        with patch.object(_sync_events, "publish_after_log", side_effect=_publish):
            _sync_events.publish_after_log_detached(lambda _reason: None)
            assert done.wait(timeout=5), "publish never ran"

    def test_reports_a_failure_through_the_callback(self) -> None:
        """A publish outage still surfaces, just after the caller returned."""
        seen: list[str] = []
        finished = threading.Event()

        def _record(reason: str) -> None:
            seen.append(reason)
            finished.set()

        with patch.object(_sync_events, "publish_after_log", return_value="no token"):
            _sync_events.publish_after_log_detached(_record)
            assert finished.wait(timeout=5), "callback never fired"

        assert seen == ["no token"]

    def test_stays_quiet_on_success(self) -> None:
        """Nothing to report means the callback is never called."""
        calls: list[str] = []
        with patch.object(_sync_events, "publish_after_log", return_value=None):
            _sync_events.publish_after_log_detached(calls.append)
            for thread in threading.enumerate():
                if thread is not threading.current_thread():
                    thread.join(timeout=5)

        assert calls == []
