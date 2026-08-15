"""Tests for the cross-device sync orchestration.

The GitHub layer is mocked (no network access); conftest.py's
``_isolate_state``/``_hmac_key`` fixtures provide the rest of the isolation
(sync token path, food log path, a deterministic HMAC key).
"""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest

from diet_guard import _sync, _sync_client
from diet_guard._device import device_id
from diet_guard._foodbank import lookup_food
from diet_guard._state import load_log, log_meal
from diet_guard.tests._sync_fakes import _mock_client, _nutrition, _write_token


class TestReadToken:
    def test_missing_token_file_raises_sync_error(self) -> None:
        with pytest.raises(_sync.SyncError):
            _sync_client._read_token()

    def test_empty_token_file_raises_sync_error(self) -> None:
        _write_token("   ")
        with pytest.raises(_sync.SyncError):
            _sync_client._read_token()

    def test_present_token_is_read_and_stripped(self) -> None:
        _write_token("  abc123  \n")
        assert _sync_client._read_token() == "abc123"


class TestRunSync:
    def test_raises_before_touching_github_when_no_token(self) -> None:
        with (
            patch.object(_sync_client, "GitHubSyncClient") as client_cls,
            pytest.raises(_sync.SyncError),
        ):
            _sync.run_sync()
        client_cls.assert_not_called()

    def test_pushes_local_log_when_no_other_devices_have_synced(self) -> None:
        _write_token()
        log_meal("oatmeal", _nutrition(), slot=8)
        client = _mock_client(devices=())
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            merged = _sync.run_sync()

        assert sum(len(entries) for entries in merged.values()) == 1
        pushed = [call.args[0] for call in client.put_file_text.call_args_list]
        # The log push, the derived bank rebuilt from that same log, and this
        # device's revision -- published *after* the log, so a peer can never
        # cache "seen rev X" against a log it never received.
        assert pushed == [
            f"diet-guard-sync/devices/{device_id()}/food_bank.json",
            f"diet-guard-sync/devices/{device_id()}/food_log.json",
            f"diet-guard-sync/revs/{device_id()}",
        ]
        log_call = next(
            call
            for call in client.put_file_text.call_args_list
            if call.args[0].endswith("food_log.json")
        )
        pushed_json = log_call.args[1]
        pushed = json.loads(pushed_json)
        (record,) = pushed.values()
        assert "fields" in record
        assert "id" in record

    def test_skips_its_own_device_id_when_listing(self) -> None:
        _write_token()
        client = _mock_client(
            devices=("pc", "phone"),
            files={"diet-guard-sync/devices/phone/food_log.json": "{}"},
        )
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        # Every pull -- food log, budget, curated bank -- skips "pc" (this
        # device) and only ever reads "phone"'s files.
        requested_paths = [call.args[0] for call in client.get_file_text.call_args_list]
        assert requested_paths == [
            "diet-guard-sync/devices/phone/food_log.json",
            "diet-guard-sync/devices/phone/budget.json",
            "diet-guard-sync/devices/phone/food_bank.json",
            "diet-guard-sync/devices/phone/food_bank_manual.json",
        ]

    def test_skips_a_device_with_no_pushed_file_yet(self) -> None:
        _write_token()
        client = _mock_client(devices=("phone",), files={})
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            merged = _sync.run_sync()
        assert merged == {}

    def test_ignores_a_device_whose_pushed_file_is_not_a_json_object(self) -> None:
        _write_token()
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_log.json": "[]"},
        )
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            merged = _sync.run_sync()
        assert merged == {}

    def test_skips_a_device_whose_pushed_file_is_corrupt_json(self) -> None:
        """An interrupted/truncated push must not crash every other device's
        merge -- it is treated the same as a device that hasn't pushed yet.
        """
        _write_token()
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_log.json": "{not valid json"},
        )
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
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
            files={"diet-guard-sync/devices/phone/food_log.json": remote_log_json},
        )
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
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
            files={"diet-guard-sync/devices/phone/food_log.json": remote_log_json},
        )
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()

        reloaded = load_log()
        descs = {entry["desc"] for entries in reloaded.values() for entry in entries}
        assert "phone meal" in descs

    def test_rebuilds_the_food_bank_after_merge(self) -> None:
        _write_token()
        log_meal("oatmeal", _nutrition(), slot=8)
        client = _mock_client(devices=())
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert lookup_food("oatmeal") is not None
