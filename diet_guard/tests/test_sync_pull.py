"""Tests for pulling peers' logs: revisions, skips and push suppression.

Split out of ``test_sync.py`` to keep both files under the repo's 250-line
cap. Covers the revision cache that lets a tick skip an unchanged peer, and
the no-op push suppression that keeps an idle tick from rewriting the remote.
"""

from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

from crdt_sync import (
    FirebaseAuthError,
    FirebaseSyncError,
    GitHubSyncError,
    SyncState,
)
import pytest

from diet_guard import _sync, _sync_client
from diet_guard._device import device_id, device_identity
from diet_guard.tests._sync_fakes import _mock_client, _write_token


class TestPullSharedLog:
    """The fail-closed wrapper the gate and the lock-screen button share."""

    def test_returns_none_on_success(self) -> None:
        """A clean pull returns None (no reason to report)."""
        with patch.object(_sync, "run_sync") as run_sync:
            assert _sync.pull_shared_log() is None
        run_sync.assert_called_once_with()

    def test_returns_reason_on_expected_failure(self) -> None:
        """A real sync failure (here a network error) becomes a reason string."""
        with patch.object(_sync, "run_sync", side_effect=_sync.GitHubSyncError("boom")):
            reason = _sync.pull_shared_log()
        assert reason is not None
        assert "boom" in reason

    @pytest.mark.parametrize(
        "error",
        [
            FirebaseAuthError("token refresh rejected"),
            FirebaseSyncError("RTDB unavailable"),
        ],
    )
    def test_firebase_failure_fails_closed(self, error: Exception) -> None:
        """A Firebase failure must return a reason, never raise.

        Regression guard: ``FirebaseAuthError``/``FirebaseSyncError`` are
        *siblings* of ``GitHubSyncError`` under ``RemoteSyncError``, not
        subclasses. Catching only the GitHub type let every per-request
        failure of the *primary* backend escape, so the gate's "Fetch from
        sync" button raised a traceback instead of reporting a reason and
        leaving the lock up -- on the exact path this helper exists to
        fail closed.
        """
        with patch.object(_sync, "run_sync", side_effect=error):
            reason = _sync.pull_shared_log()

        assert reason is not None
        assert str(error) in reason

    def test_unexpected_error_is_not_swallowed(self) -> None:
        """A bug outside the known failure surface surfaces, not hidden."""
        with (
            patch.object(_sync, "run_sync", side_effect=KeyError("bug")),
            pytest.raises(KeyError),
        ):
            _sync.pull_shared_log()


class TestRemoteRevisions:
    """Reading the peers' revision map, which gates the big downloads."""

    def test_is_empty_without_a_bulk_map_read(self) -> None:
        """GitHub has none; correctness must not depend on the optimisation."""
        client = MagicMock()
        del client.get_string_map

        assert _sync._remote_revisions(client) == {}

    def test_returns_the_published_revisions(self) -> None:
        client = MagicMock()
        client.get_string_map.return_value = {"phone": "abc"}

        assert _sync._remote_revisions(client) == {"phone": "abc"}

    def test_an_unreadable_map_degrades_to_fetching_everything(self) -> None:
        """Not worth failing a sync over; every peer is simply fetched."""
        client = MagicMock()
        client.get_string_map.side_effect = GitHubSyncError("boom")

        assert _sync._remote_revisions(client) == {}


class TestPullSkipsUnchangedPeers:
    """The single largest traffic saving in the fleet."""

    def test_skips_a_peer_whose_revision_is_unchanged(self) -> None:
        client = _mock_client(devices=("phone",))
        state = SyncState(pushed_rev=None, peer_revs={"phone": "rev-1"})
        seen: dict[str, str] = {}

        logs = _sync._pull_remote_logs(
            client, {"phone": "rev-1"}, state, seen, device_identity()
        )

        assert logs == []
        assert seen == {"phone": "rev-1"}
        client.get_file_text.assert_not_called()

    def test_downloads_a_peer_whose_revision_moved(self) -> None:
        text = json.dumps({})
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_log.json": text},
        )
        state = SyncState(pushed_rev=None, peer_revs={"phone": "rev-1"})
        seen: dict[str, str] = {}

        _sync._pull_remote_logs(
            client, {"phone": "rev-2"}, state, seen, device_identity()
        )

        client.get_file_text.assert_called_once()
        assert seen == {"phone": "rev-2"}


class TestNoOpPushSuppression:
    """88% of the old GitHub history was byte-identical no-op pushes."""

    def test_a_second_unchanged_sync_pushes_no_log(self) -> None:
        """The saving the free-tier budget depends on, at 96 ticks a day."""
        _write_token()
        client = _mock_client()

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
            pushed_first = [
                call.args[0] for call in client.put_file_text.call_args_list
            ]
            client.put_file_text.reset_mock()
            _sync.run_sync()

        pushed_second = [call.args[0] for call in client.put_file_text.call_args_list]
        assert f"diet-guard-sync/devices/{device_id()}/food_log.json" in pushed_first
        assert (
            f"diet-guard-sync/devices/{device_id()}/food_log.json" not in pushed_second
        )
        assert f"diet-guard-sync/revs/{device_id()}" not in pushed_second
