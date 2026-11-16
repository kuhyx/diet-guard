"""A meal logged while a peer pull is in flight must survive it.

The gate now pulls on a timer, so a pull's network reads can overlap the user's
own "Log & Continue". The merge must therefore read the local log *after* the
peers have been fetched, immediately before the write -- not seconds earlier.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard import _sync_client, _sync_refresh
from diet_guard._state import log_meal
from diet_guard._state_sync import read_raw_log
from diet_guard.tests._sync_fakes import _mock_client, _nutrition, _write_token
from diet_guard.tests.test_sync_refresh import _peer_log_text

if TYPE_CHECKING:
    from crdt_sync import RemoteStore


def _descs() -> set[str]:
    return {
        str(entry.get("desc"))
        for entries in read_raw_log().values()
        for entry in entries
    }


def test_a_meal_logged_during_the_peer_read_is_not_overwritten() -> None:
    _write_token()
    text = _peer_log_text()
    client = _mock_client(
        devices=("phone",),
        files={"diet-guard-sync/devices-e2e/phone/food_log.json": text},
    )
    real_read = _sync_refresh.read_sealed

    def read_then_user_logs(store: RemoteStore, path: str) -> str | None:
        got = real_read(store, path)
        log_meal("typed meanwhile", _nutrition(), 12)  # lands mid-pull
        return got

    with (
        patch.object(_sync_client, "GitHubSyncClient", return_value=client),
        patch.object(_sync_refresh, "read_sealed", read_then_user_logs),
    ):
        _sync_refresh.refresh_peer_logs()

    assert _descs() == {"peer porridge", "typed meanwhile"}
