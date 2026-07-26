"""Tests for the food bank's half of the sync tick.

Split out of ``test_sync.py`` to keep both files under the repo's 500-line
ceiling. Covers the derived bank (merged max-count-wins, with the log
authoritative for which foods exist) and the hand-curated bank (merged
last-writer-wins per food name).
"""

from __future__ import annotations

import json
from unittest.mock import patch

from diet_guard import _sync
from diet_guard._estimator import Nutrition
from diet_guard._foodbank import lookup_food, read_food_bank
from diet_guard._foodbank_manual import add_manual_entry, read_manual_bank
from diet_guard._state import log_meal
from diet_guard._sync_merge import food_bank_to_log, manual_bank_to_log
from diet_guard.tests.test_sync import _mock_client, _write_token


class TestSyncFoodBank:
    """The log-derived food bank's cross-device merge."""

    def test_the_local_bank_is_pushed(self) -> None:
        _write_token()
        # Through the log, not remember_food: run_sync rebuilds the derived
        # bank from the merged log first, so a bank entry with no log entry
        # behind it is (correctly) discarded before the push.
        log_meal("apple", Nutrition(95, 0.5, 25, 0.3, 180, "manual"), 8)
        client = _mock_client(devices=())
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        pushed = [call.args[0] for call in client.put_file_text.call_args_list]
        assert "diet-guard-sync/devices/pc/food_bank.json" in pushed

    def test_a_food_the_phone_logged_reaches_the_gate(self) -> None:
        """The payoff: a food eaten on the phone autocompletes on the PC.

        It arrives through the *log* (which merges first in the same tick),
        and the bank rebuild picks it up -- membership follows the log, so
        this is the path that actually delivers cross-device autocomplete.
        """
        _write_token()
        remote_log_json = json.dumps(
            {
                "2026-06-22": [
                    {
                        "id": "phone-skyr",
                        "time": "2026-06-22T09:00:00+02:00",
                        "desc": "Skyr",
                        "kcal": 120.0,
                        "protein_g": 20.0,
                        "carbs_g": 5.0,
                        "fat_g": 0.5,
                        "grams": 150.0,
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
            _sync.run_sync()
        found = lookup_food("Skyr")
        assert found is not None
        assert found.kcal == 120.0

    def test_a_deleted_food_is_not_resurrected_by_a_peer(self) -> None:
        """Regression: a CRDT union never shrinks.

        Without the log staying authoritative for membership, a peer's stale
        copy of a food whose entries were all undone out-clocks the local
        absence, gets written back AND re-pushed -- permanently un-deletable.
        """
        _write_token()
        # This device's log knows nothing of "skyr" (its entries were undone).
        log_meal("apple", Nutrition(95, 0.5, 25, 0.3, 180, "manual"), 8)
        remote = json.dumps(
            {
                rid: rec.to_dict()
                for rid, rec in food_bank_to_log(
                    {"skyr": {"desc": "Skyr", "kcal": 120.0, "count": 3}},
                ).items()
            },
        )
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_bank.json": remote},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()

        assert lookup_food("Skyr") is None
        pushed = [
            call.args[1]
            for call in client.put_file_text.call_args_list
            if call.args[0].endswith("food_bank.json")
        ]
        assert pushed
        assert "skyr" not in pushed[0]

    def test_a_higher_remote_count_still_refines_a_known_food(self) -> None:
        """Membership defers to the log; content still takes the better count."""
        _write_token()
        log_meal("apple", Nutrition(95, 0.5, 25, 0.3, 180, "manual"), 8)
        remote = json.dumps(
            {
                rid: rec.to_dict()
                for rid, rec in food_bank_to_log(
                    {"apple": {"desc": "Apple", "kcal": 95.0, "count": 99}},
                ).items()
            },
        )
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_bank.json": remote},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert read_food_bank()["apple"]["count"] == 99

    def test_unparsable_remote_food_bank_is_skipped(self) -> None:
        _write_token()
        log_meal("apple", Nutrition(95, 0.5, 25, 0.3, 180, "manual"), 8)
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_bank.json": "{not json"},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert lookup_food("apple") is not None

    def test_nothing_pushed_when_no_device_has_a_bank(self) -> None:
        _write_token()
        client = _mock_client(devices=())
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        pushed = [call.args[0] for call in client.put_file_text.call_args_list]
        assert "diet-guard-sync/devices/pc/food_bank.json" not in pushed


class TestSyncManualBank:
    """The hand-curated food bank's cross-device merge."""

    def test_nothing_pushed_when_no_device_has_curated_anything(self) -> None:
        _write_token()
        client = _mock_client(devices=())
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        pushed = [call.args[0] for call in client.put_file_text.call_args_list]
        assert not any("food_bank_manual" in path for path in pushed)

    def test_local_curated_entry_is_pushed(self) -> None:
        _write_token()
        add_manual_entry("Skyr", {"desc": "Skyr", "kcal": 120.0, "count": 0})
        client = _mock_client(devices=())
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        pushed = [call.args[0] for call in client.put_file_text.call_args_list]
        assert "diet-guard-sync/devices/pc/food_bank_manual.json" in pushed

    def test_a_remote_curated_entry_is_adopted_locally(self) -> None:
        """The point of the whole feature: a food added on the phone is usable
        on the PC, in the gate's autocomplete, without ever being eaten."""
        _write_token()
        remote = json.dumps(
            {
                record_id: record.to_dict()
                for record_id, record in manual_bank_to_log(
                    {
                        "skyr": {
                            "desc": "Skyr",
                            "kcal": 120.0,
                            "protein_g": 20.0,
                            "carbs_g": 5.0,
                            "fat_g": 0.5,
                            "grams": 150.0,
                            "count": 0,
                            "t": "2026-07-26T10:00:00+02:00",
                        },
                    },
                ).items()
            },
        )
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_bank_manual.json": remote},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert "skyr" in read_manual_bank()
        found = lookup_food("Skyr")
        assert found is not None
        assert found.kcal == 120.0

    def test_a_newer_remote_edit_wins(self) -> None:
        _write_token()
        add_manual_entry("Skyr", {"desc": "Skyr", "kcal": 120.0, "count": 0})
        remote = json.dumps(
            {
                record_id: record.to_dict()
                for record_id, record in manual_bank_to_log(
                    {
                        "skyr": {
                            "desc": "Skyr",
                            "kcal": 999.0,
                            "count": 0,
                            "t": "2999-01-01T00:00:00+02:00",
                        },
                    },
                ).items()
            },
        )
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/food_bank_manual.json": remote},
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert read_manual_bank()["skyr"]["kcal"] == 999.0

    def test_unparsable_remote_curated_bank_is_skipped(self) -> None:
        _write_token()
        add_manual_entry("Skyr", {"desc": "Skyr", "kcal": 120.0, "count": 0})
        client = _mock_client(
            devices=("phone",),
            files={
                "diet-guard-sync/devices/phone/food_bank_manual.json": "{not json",
            },
        )
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert read_manual_bank()["skyr"]["kcal"] == 120.0

    def test_a_device_with_no_pushed_curated_bank_is_skipped(self) -> None:
        _write_token()
        add_manual_entry("Skyr", {"desc": "Skyr", "kcal": 120.0, "count": 0})
        client = _mock_client(devices=("phone",))
        with patch.object(_sync, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert read_manual_bank()["skyr"]["kcal"] == 120.0
