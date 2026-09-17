"""Tests for the sync subcommand's handler, split out of test_cli.py
alongside its source module (see _cli_sync.py's module docstring).
"""

from __future__ import annotations

from unittest.mock import patch

from crdt_sync import GitHubSyncError

from diet_guard import _cli_sync
from diet_guard._sync import SyncError


class TestCmdSync:
    def test_reports_synced_entry_count(self) -> None:
        merged = {
            "2026-06-22": [{"id": "a"}, {"id": "b"}],
            "2026-06-21": [{"id": "c"}],
        }
        lines: list[str] = []
        with (
            patch.object(_cli_sync, "run_sync", return_value=merged),
            patch.object(_cli_sync, "refresh_weight_from_phone") as refresh,
        ):
            assert _cli_sync.cmd_sync(lines.append) == 0
        assert lines == ["synced: 3 entries across 2 day(s)."]
        # The phone's weigh-in is applied after the merge, through the same
        # sink, so its one line lands under the sync summary.
        refresh.assert_called_once_with(lines.append)

    def test_a_failed_sync_does_not_touch_the_weight(self) -> None:
        with (
            patch.object(_cli_sync, "run_sync", side_effect=SyncError("no token")),
            patch.object(_cli_sync, "refresh_weight_from_phone") as refresh,
        ):
            assert _cli_sync.cmd_sync(lambda _line: None) == 1
        refresh.assert_not_called()

    def test_reports_sync_error_as_not_configured(self) -> None:
        lines: list[str] = []
        with patch.object(
            _cli_sync,
            "run_sync",
            side_effect=SyncError("no token"),
        ):
            assert _cli_sync.cmd_sync(lines.append) == 1
        assert lines == ["sync not configured: no token"]

    def test_reports_github_sync_error_as_failed(self) -> None:
        lines: list[str] = []
        with patch.object(
            _cli_sync,
            "run_sync",
            side_effect=GitHubSyncError("network down"),
        ):
            assert _cli_sync.cmd_sync(lines.append) == 1
        assert lines == ["sync failed: network down"]
