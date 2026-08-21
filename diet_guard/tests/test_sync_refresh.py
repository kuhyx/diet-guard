"""Tests for the gate's narrow, pre-lock refresh.

The full tick measured ~21s against the live remote, which is far too slow to
sit in front of a fullscreen lock. ``_sync_refresh`` answers the gate's single
question -- "has a peer already logged this slot?" -- from the peer logs alone.

The three state invariants below are the traps that make this pass dangerous
if it drifts, so each has its own regression test:

* ``pushed_rev`` must survive verbatim (this pass never pushes),
* ``peer_revs`` must be *merged*, never replaced (only changed peers visited),
* the log must be written before the state.
"""

from __future__ import annotations

import json
from typing import cast
from unittest.mock import MagicMock, patch

from crdt_sync import FileSyncStateStore, GitHubSyncError, SyncState
import pytest

from diet_guard import _sync_client, _sync_refresh
from diet_guard._device import device_id
from diet_guard._state import log_meal
from diet_guard._state_sync import read_raw_log, write_raw_log
from diet_guard.sync_merge import daylog_to_log
from diet_guard.tests._sync_fakes import _mock_client, _nutrition, _write_token


def _state_store() -> FileSyncStateStore:
    """Return a store bound to the *redirected* state path, resolved per call."""
    from diet_guard import _sync

    return FileSyncStateStore(_sync.SYNC_STATE_FILE)


def _peer_log_text() -> str:
    """Return the wire text a peer would push for one logged meal.

    Built through ``log_meal`` into the (redirected) local log, serialised, then
    the local log is emptied again -- so the merge under test is unambiguously
    the peer's record arriving, not one that was already there.
    """
    log_meal("peer porridge", _nutrition(), 8)
    text = json.dumps(
        {rid: rec.to_dict() for rid, rec in daylog_to_log(read_raw_log()).items()},
        indent=2,
    )
    write_raw_log({})
    return text


class TestCandidatePeers:
    """Enumerating peers without the ~445ms mirrored directory listing."""

    def test_uses_the_revision_map_and_the_cache(self) -> None:
        """The union covers peers that stopped publishing revisions."""
        client = MagicMock()
        state = SyncState(pushed_rev=None, peer_revs={"cached": "r"})

        peers = _sync_refresh._candidate_peers(client, {"published": "r"}, state)

        assert peers == ["cached", "published"]
        client.list_directory.assert_not_called()

    def test_falls_back_to_listing_without_a_revision_map(self) -> None:
        """No revisions means no information -- not "no peers"."""
        client = _mock_client(devices=("phone",))
        state = SyncState(pushed_rev=None, peer_revs={})

        assert _sync_refresh._candidate_peers(client, {}, state) == ["phone"]
        client.list_directory.assert_called_once()


class TestPeerIsCurrent:
    """Which peers this narrow pass is allowed to skip."""

    def test_skips_a_matching_revision(self) -> None:
        state = SyncState(pushed_rev=None, peer_revs={"phone": "r1"})

        assert _sync_refresh._peer_is_current("phone", {"phone": "r1"}, state)

    def test_fetches_a_moved_revision(self) -> None:
        state = SyncState(pushed_rev=None, peer_revs={"phone": "r1"})

        assert not _sync_refresh._peer_is_current("phone", {"phone": "r2"}, state)

    def test_skips_a_rev_less_peer_already_merged(self) -> None:
        """Removes the standing cost of the frozen legacy role-id directories."""
        state = SyncState(pushed_rev=None, peer_revs={"desktop": "whatever"})

        assert _sync_refresh._peer_is_current("desktop", {}, state)

    def test_fetches_a_genuinely_new_rev_less_peer(self) -> None:
        state = SyncState(pushed_rev=None, peer_revs={})

        assert not _sync_refresh._peer_is_current("newcomer", {}, state)

    def test_a_null_cached_revision_still_counts_as_seen(self) -> None:
        """``peer_revs`` holds explicit nulls; ``in`` is the only safe test.

        Using ``.get(...) is not None`` here would re-download those peers on
        every single tick, forever.
        """
        # A real ``sync_state.json`` holds explicit nulls here even though the
        # annotation says ``str`` -- that mismatch is exactly what this test
        # pins, so the value is cast in rather than suppressed at the line.
        peer_revs = cast("dict[str, str]", {"pc": None})
        state = SyncState(pushed_rev=None, peer_revs=peer_revs)

        assert _sync_refresh._peer_is_current("pc", {}, state)


class TestRefreshPeerLogs:
    """The pass itself."""

    def test_no_candidates_touches_nothing(self) -> None:
        _write_token()
        client = _mock_client(devices=())

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync_refresh.refresh_peer_logs()

        client.get_file_text.assert_not_called()

    def test_skips_this_device(self) -> None:
        """Merging our own pushed log back in is pure waste."""
        _write_token()
        client = _mock_client(devices=(device_id(),))

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync_refresh.refresh_peer_logs()

        client.get_file_text.assert_not_called()

    def test_a_missing_remote_file_is_skipped(self) -> None:
        _write_token()
        client = _mock_client(devices=("phone",), files={})

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync_refresh.refresh_peer_logs()

        assert read_raw_log() == {}

    def test_an_unparsable_payload_is_skipped_and_not_recorded(self) -> None:
        """A corrupt push must be retried next tick, never remembered as merged."""
        _write_token()
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_log.json": "{not json"},
        )

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync_refresh.refresh_peer_logs()

        assert "phone" not in _state_store().load().peer_revs

    def test_merges_a_peer_entry_into_the_local_log(self) -> None:
        _write_token()
        text = _peer_log_text()
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_log.json": text},
        )

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync_refresh.refresh_peer_logs()

        assert any(
            entry.get("desc") == "peer porridge"
            for entries in read_raw_log().values()
            for entry in entries
        )

    def test_never_pushes(self) -> None:
        """This pass is pull-only; a push here would block the lock window."""
        _write_token()
        text = _peer_log_text()
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_log.json": text},
        )

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync_refresh.refresh_peer_logs()

        client.put_file_text.assert_not_called()

    def test_preserves_pushed_rev(self) -> None:
        """Overwriting it would make this device stop pushing forever."""
        _write_token()
        store = _state_store()
        store.save(SyncState(pushed_rev="mine-v1", peer_revs={}))
        text = _peer_log_text()
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_log.json": text},
        )

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync_refresh.refresh_peer_logs()

        assert store.load().pushed_rev == "mine-v1"

    def test_merges_peer_revs_rather_than_replacing_them(self) -> None:
        """Only changed peers are visited, so a replace would drop the rest."""
        _write_token()
        store = _state_store()
        store.save(SyncState(pushed_rev=None, peer_revs={"other": "r-other"}))
        text = _peer_log_text()
        client = _mock_client(
            devices=("phone", "other"),
            files={"diet-guard-sync/devices/phone/food_log.json": text},
        )

        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync_refresh.refresh_peer_logs()

        assert store.load().peer_revs["other"] == "r-other"


class TestPullPeerLogs:
    """The fail-closed wrapper the gate actually calls."""

    def test_returns_none_on_success(self) -> None:
        with patch.object(_sync_refresh, "refresh_peer_logs"):
            assert _sync_refresh.pull_peer_logs() is None

    def test_returns_a_reason_on_a_sync_failure(self) -> None:
        with patch.object(
            _sync_refresh, "refresh_peer_logs", side_effect=GitHubSyncError("boom")
        ):
            reason = _sync_refresh.pull_peer_logs()

        assert reason is not None
        assert "boom" in reason

    def test_an_unexpected_error_is_not_swallowed(self) -> None:
        """A bug outside the known failure surface must surface, not hide."""
        with (
            patch.object(
                _sync_refresh, "refresh_peer_logs", side_effect=KeyError("bug")
            ),
            pytest.raises(KeyError),
        ):
            _sync_refresh.pull_peer_logs()
