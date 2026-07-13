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
from diet_guard._budget import daily_budget, write_budget
from diet_guard._estimator import Nutrition
from diet_guard._foodbank import lookup_food
from diet_guard._state import load_log, log_meal
from diet_guard._sync_merge import budget_to_log


def _remote_budget_json(*, kcal: int, t: str, weight_kg: float | None = None) -> str:
    """Build the wire text a remote device would push for a given budget edit."""
    record: dict[str, object] = {"v": 2, "b": kcal, "t": t}
    if weight_kg is not None:
        record["w"] = weight_kg
    log = budget_to_log(record)
    return json.dumps({rid: rec.to_dict() for rid, rec in log.items()}, indent=2)


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
    client.get_file_text.side_effect = resolved_files.get
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
        assert pushed_path == "diet-guard-sync/devices/pc/food_log.json"
        pushed_json = client.put_file_text.call_args.args[1]
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
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        # Both the food-log and budget pulls skip "pc" (this device) and
        # only ever read "phone"'s files -- never "pc"'s.
        requested_paths = [call.args[0] for call in client.get_file_text.call_args_list]
        assert requested_paths == [
            "diet-guard-sync/devices/phone/food_log.json",
            "diet-guard-sync/devices/phone/budget.json",
        ]

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
            files={"diet-guard-sync/devices/phone/food_log.json": "[]"},
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
            files={"diet-guard-sync/devices/phone/food_log.json": "{not valid json"},
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
            files={"diet-guard-sync/devices/phone/food_log.json": remote_log_json},
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
            files={"diet-guard-sync/devices/phone/food_log.json": remote_log_json},
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


class TestSyncBudget:
    """The daily budget's last-writer-wins sync, folded into run_sync()."""

    def test_pushes_local_budget_when_no_other_devices_have_synced(self) -> None:
        _write_token()
        write_budget(2000)
        client = _mock_client(devices=())
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        pushed_paths = {call.args[0] for call in client.put_file_text.call_args_list}
        assert "diet-guard-sync/devices/pc/budget.json" in pushed_paths

    def test_nothing_pushed_when_no_budget_ever_set(self) -> None:
        """An uninitialized device contributes nothing -- no push, no crash."""
        _write_token()
        client = _mock_client(devices=())
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        pushed_paths = {call.args[0] for call in client.put_file_text.call_args_list}
        assert "diet-guard-sync/devices/pc/budget.json" not in pushed_paths

    def test_remote_only_budget_is_adopted_locally(self) -> None:
        """Only the phone has ever set a budget -- the PC adopts it."""
        _write_token()
        remote_json = _remote_budget_json(kcal=1800, t="2026-01-01T09:00:00")
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/budget.json": remote_json},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert daily_budget() == 1800

    def test_local_edit_later_than_remote_wins(self) -> None:
        """A fresh local write beats a much older remote edit."""
        _write_token()
        write_budget(1500)  # stamped with "now"
        remote_json = _remote_budget_json(kcal=1800, t="2020-01-01T09:00:00")
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/budget.json": remote_json},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert daily_budget() == 1500

    def test_remote_edit_later_than_local_wins(self) -> None:
        """A remote edit far in the future beats a stale local write.

        Confirms this is genuinely edit-time (not sync-time or push-order)
        LWW: whichever side has the later ``t`` wins regardless of which
        device happens to run its sync tick first.
        """
        _write_token()
        write_budget(1500)  # stamped with "now"
        remote_json = _remote_budget_json(kcal=1800, t="2999-01-01T09:00:00")
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/budget.json": remote_json},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert daily_budget() == 1800

    def test_malformed_remote_budget_is_skipped(self) -> None:
        """A corrupt remote budget.json is skipped, not a crash."""
        _write_token()
        write_budget(2000)
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/budget.json": "{not valid json"},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert daily_budget() == 2000


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

    def test_unexpected_error_is_not_swallowed(self) -> None:
        """A bug outside the known failure surface surfaces, not hidden."""
        with (
            patch.object(_sync, "run_sync", side_effect=KeyError("bug")),
            pytest.raises(KeyError),
        ):
            _sync.pull_shared_log()
