"""Tests for the budget's half of the sync tick.

Split out of ``test_sync.py`` to keep both files under the repo's 250-line
cap, along the same seam as the module they cover
(``diet_guard.sync_merge._budget``).
"""

from __future__ import annotations

from unittest.mock import patch

from diet_guard import _sync, _sync_client
from diet_guard._budget import daily_budget, write_budget
from diet_guard._budget_derived import budget_weight
from diet_guard._budget_history import load_entries
from diet_guard._device import device_id
from diet_guard._meal_schedule import MealSchedule
from diet_guard._meal_schedule_store import (
    load_entries as load_schedule_entries,
)
from diet_guard._meal_schedule_store import record_schedule_change
from diet_guard.tests._sync_fakes import (
    _mock_client,
    _remote_budget_json,
    _write_token,
)


class TestSyncBudget:
    """The daily budget's last-writer-wins sync, folded into run_sync()."""

    def test_pushes_local_budget_when_no_other_devices_have_synced(self) -> None:
        _write_token()
        write_budget(2000)
        client = _mock_client(devices=())
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        pushed_paths = {call.args[0] for call in client.put_file_text.call_args_list}
        assert f"diet-guard-sync/devices/{device_id()}/budget.json" in pushed_paths

    def test_nothing_pushed_when_no_budget_ever_set(self) -> None:
        """An uninitialized device contributes nothing -- no push, no crash."""
        _write_token()
        client = _mock_client(devices=())
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        pushed_paths = {call.args[0] for call in client.put_file_text.call_args_list}
        assert f"diet-guard-sync/devices/{device_id()}/budget.json" not in pushed_paths

    def test_remote_only_budget_is_adopted_locally(self) -> None:
        """Only the phone has ever set a budget -- the PC adopts it."""
        _write_token()
        remote_json = _remote_budget_json(kcal=1800, t="2026-01-01T09:00:00")
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/budget.json": remote_json},
        )
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
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
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
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
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert daily_budget() == 1800

    def test_a_remote_edit_does_not_delete_the_local_body_weight(self) -> None:
        """The w-loss bug: ``w`` is PC-local and must survive a phone edit.

        ``w`` never travels (budget_to_log strips it), so before this fix a
        winning remote record replaced the whole stored map and silently took
        the weight -- and the protein target -- with it.
        """
        _write_token()
        write_budget(1500, weight_kg=78.5)
        remote_json = _remote_budget_json(kcal=1800, t="2999-01-01T09:00:00")
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/budget.json": remote_json},
        )
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert daily_budget() == 1800
        assert budget_weight() == 78.5

    def test_budget_history_survives_a_round_trip(self) -> None:
        """The history is written back locally after every merge."""
        _write_token()
        write_budget(2000)
        client = _mock_client(devices=())
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert load_entries()[-1].kcal == 2000

    def test_meal_schedule_survives_a_round_trip(self) -> None:
        """The meal schedule is written back locally after every merge.

        Without this the schedule would be device-local: the phone could set
        five meals while the PC still derived four, and the PC's gate would
        nag for a checkpoint the phone never offered.
        """
        _write_token()
        write_budget(2000)
        record_schedule_change(MealSchedule(8, 20, 5))
        client = _mock_client(devices=())
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert load_schedule_entries()[-1].schedule == MealSchedule(8, 20, 5)

    def test_malformed_remote_budget_is_skipped(self) -> None:
        """A corrupt remote budget.json is skipped, not a crash."""
        _write_token()
        write_budget(2000)
        client = _mock_client(
            devices=("phone",),
            files={"diet-guard-sync/devices/phone/budget.json": "{not valid json"},
        )
        with patch.object(_sync_client, "GitHubSyncClient", return_value=client):
            _sync.run_sync()
        assert daily_budget() == 2000
