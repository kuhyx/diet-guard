"""Tests for this machine's persisted sync device id.

Split out of ``test_sync.py`` to keep it under the repo's 500-line cap.
Covers the migration from the fixed ``"pc"`` role constant to a per-install
uuid -- specifically that the old path is still recognised as this device's
own, so its pre-migration log is not re-merged as a peer's.
"""

from __future__ import annotations

from unittest.mock import MagicMock

from crdt_sync import DeviceIdentity, SyncState

from diet_guard import _sync
from diet_guard._device import device_id, device_identity


def _mock_client(*, devices: tuple[str, ...] = ()) -> MagicMock:
    """Build a mock sync client that lists ``devices`` and holds no files."""
    client = MagicMock()
    client.list_directory.return_value = list(devices)
    client.get_file_text.side_effect = lambda _path: None
    del client.get_string_map
    return client


class TestPullSkipsOwnLegacyPath:
    """The uuid migration leaves this device's old 'pc' log behind."""

    def test_skips_the_devices_own_legacy_id(self) -> None:
        """devices/pc/ is this machine's own history, not a peer's.

        Without the legacy id in the skip set, every tick would download and
        re-merge the log this machine pushed before it migrated -- idempotent
        under LWW, but hundreds of KB of pure waste, 96 times a day.
        """
        client = _mock_client(devices=("pc", "phone"))
        state = SyncState(pushed_rev=None, peer_revs={})

        _, _seen = _sync._pull_remote_logs(
            client,
            {},
            state,
            identity=device_identity(),
            device_ids=("pc", "phone"),
        )

        fetched = [call.args[0] for call in client.get_file_text.call_args_list]
        assert "diet-guard-sync/devices/pc/food_log.json" not in fetched
        assert "diet-guard-sync/devices/phone/food_log.json" in fetched

    def test_pulls_the_legacy_path_once_it_is_disowned(self) -> None:
        """Negative control: with no legacy id, devices/pc/ IS a peer.

        Proves the skip above is the legacy id's doing, not an artifact of
        the fixture -- and documents what happens after the old path is
        reclaimed and SYNC_LEGACY_DEVICE_ID drops to None.
        """
        client = _mock_client(devices=("pc",))
        state = SyncState(pushed_rev=None, peer_revs={})

        _, _seen = _sync._pull_remote_logs(
            client,
            {},
            state,
            identity=DeviceIdentity(device_id=device_id()),
            device_ids=("pc",),
        )

        fetched = [call.args[0] for call in client.get_file_text.call_args_list]
        assert "diet-guard-sync/devices/pc/food_log.json" in fetched
