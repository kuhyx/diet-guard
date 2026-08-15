"""Tests for the event-driven post-log sync trigger.

These exercise the real :func:`publish_after_log`, not the conftest stub: the
autouse fixture patches it at each *call site*, so importing it here still
reaches the genuine helper (see ``conftest._isolate_state``).
"""

from __future__ import annotations

import logging
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
