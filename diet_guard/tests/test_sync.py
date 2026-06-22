"""Tests for the cross-device sync orchestration.

The GitHub layer is mocked (no network access); conftest.py's
``_isolate_state``/``_hmac_key`` fixtures provide the rest of the isolation
(sync token path, food log path, a deterministic HMAC key).
"""

from __future__ import annotations

import json
from unittest.mock import MagicMock, patch

import pytest

from diet_guard import _sync
from diet_guard._estimator import Nutrition
from diet_guard._foodbank import lookup_food
from diet_guard._state import load_log, log_meal


def _nutrition(kcal: float = 200.0) -> Nutrition:
    return Nutrition(
        kcal=kcal,
        protein_g=10.0,
        carbs_g=20.0,
        fat_g=5.0,
        grams=100.0,
        source="manual",
    )


def _write_token(token: str = "fake-token") -> None:
    _sync.SYNC_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    _sync.SYNC_TOKEN_FILE.write_text(token)


def _mock_client(
    *,
    devices: tuple[str, ...] = (),
    files: dict[str, str] | None = None,
) -> MagicMock:
    """Build a mock ``GitHubSyncClient`` covering the methods sync calls."""
    client = MagicMock()
    client.list_directory.return_value = list(devices)
    resolved_files = files or {}
    client.get_file_text.side_effect = lambda path: resolved_files.get(path)
    return client


class TestReadToken:
    def test_missing_token_file_raises_sync_error(self) -> None:
        with pytest.raises(_sync.SyncError):
            _sync._read_token()

    def test_empty_token_file_raises_sync_error(self) -> None:
        _write_token("   ")
        with pytest.raises(_sync.SyncError):
            _sync._read_token()

    def test_present_token_is_read_and_stripped(self) -> None:
        _write_token("  abc123  \n")
        assert _sync._read_token() == "abc123"


class TestRunSync:
    def test_raises_before_touching_github_when_no_token(self) -> None:
        with (
            patch.object(_sync, "GitHubSyncClient") as client_cls,
            pytest.raises(_sync.SyncError),
        ):
            _sync.run_sync()
        client_cls.assert_not_called()

    def test_pushes_local_log_when_no_other_devices_have_synced(self) -> None:
        _write_token()
        log_meal("oatmeal", _nutrition(), slot=8)
        client = _mock_client(devices=())
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            merged = _sync.run_sync()

        assert sum(len(entries) for entries in merged.values()) == 1
        client.put_file_text.assert_called_once()
        pushed_path = client.put_file_text.call_args.args[0]
        assert pushed_path == "devices/pc/food_log.json"

    def test_skips_its_own_device_id_when_listing(self) -> None:
        _write_token()
        client = _mock_client(
            devices=("pc", "phone"),
            files={"devices/phone/food_log.json": "{}"},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        client.get_file_text.assert_called_once_with(
            "devices/phone/food_log.json",
        )

    def test_skips_a_device_with_no_pushed_file_yet(self) -> None:
        _write_token()
        client = _mock_client(devices=("phone",), files={})
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            merged = _sync.run_sync()
        assert merged == {}

    def test_ignores_a_device_whose_pushed_file_is_not_a_json_object(self) -> None:
        _write_token()
        client = _mock_client(
            devices=("phone",),
            files={"devices/phone/food_log.json": "[]"},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            merged = _sync.run_sync()
        assert merged == {}

    def test_skips_a_device_whose_pushed_file_is_corrupt_json(self) -> None:
        """An interrupted/truncated push must not crash every other device's
        merge -- it is treated the same as a device that hasn't pushed yet.
        """
        _write_token()
        client = _mock_client(
            devices=("phone",),
            files={"devices/phone/food_log.json": "{not valid json"},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            merged = _sync.run_sync()
        assert merged == {}

    def test_merges_in_a_remote_devices_entries(self) -> None:
        _write_token()
        remote_log_json = json.dumps(
            {
                "2026-06-22": [
                    {
                        "id": "phone-1",
                        "time": "2026-06-22T09:00:00+02:00",
                        "desc": "phone meal",
                        "kcal": 400.0,
                        "protein_g": 20.0,
                        "carbs_g": 40.0,
                        "fat_g": 10.0,
                        "grams": 300.0,
                        "source": "manual",
                    },
                ],
            },
        )
        client = _mock_client(
            devices=("phone",),
            files={"devices/phone/food_log.json": remote_log_json},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            merged = _sync.run_sync()
        descs = {entry["desc"] for entries in merged.values() for entry in entries}
        assert "phone meal" in descs

    def test_resigns_every_entry_so_an_unsigned_remote_entry_survives_reload(
        self,
    ) -> None:
        """The data-loss trap: an unsigned phone-origin entry must not be
        silently dropped by load_log() after sync persists it locally --
        _entry_is_valid() rejects any unsigned entry once a key exists.
        """
        _write_token()
        remote_log_json = json.dumps(
            {
                "2026-06-22": [
                    {
                        "id": "phone-1",
                        "time": "2026-06-22T09:00:00+02:00",
                        "desc": "phone meal",
                        "kcal": 400.0,
                        "protein_g": 20.0,
                        "carbs_g": 40.0,
                        "fat_g": 10.0,
                        "grams": 300.0,
                        "source": "manual",
                        # No "hmac" -- the phone never holds the shared key.
                    },
                ],
            },
        )
        client = _mock_client(
            devices=("phone",),
            files={"devices/phone/food_log.json": remote_log_json},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()

        reloaded = load_log()
        descs = {entry["desc"] for entries in reloaded.values() for entry in entries}
        assert "phone meal" in descs

    def test_rebuilds_the_food_bank_after_merge(self) -> None:
        _write_token()
        log_meal("oatmeal", _nutrition(), slot=8)
        client = _mock_client(devices=())
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert lookup_food("oatmeal") is not None
