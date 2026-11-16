"""E2E sync: the copy memo, the wake-alarm ingest and the primary-only read.

Split out of ``test_sync_e2e`` to keep both files under the repo's 250-line cap.
"""

from __future__ import annotations

import json
from typing import TYPE_CHECKING
from unittest.mock import patch

from crdt_sync import (
    E2eDecryptError,
    E2eLockedError,
    MirrorSyncClient,
)
import pytest

from diet_guard import _sync_e2e
from diet_guard._body_ingest import fetch_alarm_logs
from diet_guard._sync_banks import _primary_only_text
from diet_guard.tests._sync_fakes import DictStore

if TYPE_CHECKING:
    from pathlib import Path

_OLD = "diet-guard-sync/devices"
_NEW = "diet-guard-sync/devices-e2e"
_COPY = "crdt_sync._e2e_store.copy_to_encrypted"


class TestCopyMemo:
    def _store_with_old_revs(self) -> DictStore:
        return DictStore(
            {
                f"{_OLD}/phone/budget.json": "{}",
                "diet-guard-sync/revs/phone": "rev-1",
            }
        )

    def test_a_new_process_skips_the_copy_when_old_revisions_are_unchanged(
        self,
    ) -> None:
        store = self._store_with_old_revs()
        _sync_e2e.open_e2e(store)
        with (
            patch.dict("crdt_sync._e2e_store._copied", clear=True),
            patch(_COPY, return_value=0) as copy,
        ):
            _sync_e2e.open_e2e(store)
        copy.assert_not_called()

    def test_changed_old_revisions_copy_again(self) -> None:
        store = self._store_with_old_revs()
        _sync_e2e.open_e2e(store)
        store.files["diet-guard-sync/revs/phone"] = "rev-2"
        with patch(_COPY, return_value=1) as copy:
            _sync_e2e.open_e2e(store)
        copy.assert_called_once()

    def test_the_cached_key_opens_without_the_passphrase(self, tmp_path: Path) -> None:
        store = DictStore()
        _sync_e2e.open_e2e(store)
        with patch.object(_sync_e2e, "PASSWORD_FILE", tmp_path / "gone"):
            assert _sync_e2e.open_e2e(store).layout.prefix == _NEW

    def test_wake_alarm_copies_once_per_process(self) -> None:
        store = DictStore()
        _sync_e2e.open_e2e(store, _sync_e2e.LEGACY_WAKE_ALARM_DIR)
        assert not (_sync_e2e.E2E_STATE_DIR).exists()
        with (
            patch.dict("crdt_sync._e2e_store._copied", clear=True),
            patch(_COPY, return_value=0) as copy,
        ):
            _sync_e2e.open_e2e(store, _sync_e2e.LEGACY_WAKE_ALARM_DIR)
        copy.assert_called_once()

    def test_a_copy_meeting_an_unopenable_blob_is_locked(self) -> None:
        store = DictStore()
        with (
            patch(_COPY, side_effect=E2eDecryptError("bad")),
            pytest.raises(E2eLockedError),
        ):
            _sync_e2e.open_e2e(store)


class TestWakeAlarmIngest:
    def test_old_plaintext_alarm_is_copied_and_read_decrypted(self) -> None:
        alarm = json.dumps(
            {
                "alarm": {
                    "id": "alarm",
                    "fields": {"alarm_hour": [7, "2026-11-01T00:00:00.000Z-0000-p"]},
                    "deleted": False,
                }
            }
        )
        store = DictStore({"wake-alarm-sync/devices/p1/alarm.json": alarm})
        diet = _sync_e2e.open_e2e(store)

        published = fetch_alarm_logs(diet)

        assert [device for device, _ in published] == ["p1"]
        assert json.loads(published[0][1])["alarm"]["fields"]["alarm_hour"][0] == 7
        sealed = store.files["wake-alarm-sync/devices-e2e/p1/alarm.json"]
        assert "alarm_hour" not in sealed
        assert "wake-alarm-sync/e2e" in store.files

    def test_locked_wake_alarm_is_skipped(self, tmp_path: Path) -> None:
        store = DictStore()
        diet = _sync_e2e.open_e2e(store)
        with patch.object(_sync_e2e, "PASSWORD_FILE", tmp_path / "gone"):
            assert fetch_alarm_logs(diet) == []

    def test_reads_only_the_firebase_half_of_a_mirror(self) -> None:
        primary = DictStore()
        mirror = DictStore()
        client = MirrorSyncClient(primary, mirror)
        diet = _sync_e2e.open_e2e(client)
        mirror.puts.clear()
        fetch_alarm_logs(diet)
        assert not any(p.startswith("wake-alarm-sync") for p in mirror.puts)


class TestPrimaryOnly:
    def test_e2e_store_reads_the_primary_decrypted(self) -> None:
        primary = DictStore()
        mirror = DictStore()
        diet = _sync_e2e.open_e2e(MirrorSyncClient(primary, mirror))
        path = f"{_NEW}/peer/body.json"
        diet.put_file_text(path, '{"x": 1}', message="t")
        mirror.files.pop(path)
        assert _primary_only_text(diet, path) == '{"x": 1}'
        assert '"x"' not in primary.files[path]

    def test_plain_store_is_read_directly(self) -> None:
        store = DictStore({"a/b": "text"})
        assert _primary_only_text(store, "a/b") == "text"
