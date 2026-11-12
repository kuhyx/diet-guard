"""End-to-end encryption of the sync payloads (``_sync_e2e``).

Runs the real sync tick over a dict-backed remote, so the header, the sealed
blobs and the keyed revisions are the bytes a real backend would hold.
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING
from unittest.mock import patch

from crdt_sync import (
    E2eCipher,
    E2eDecryptError,
    E2eLayout,
    E2eLockedError,
    MirrorSyncClient,
    seal_log_text,
)
import pytest

from diet_guard import _sync, _sync_client, _sync_e2e
from diet_guard._body_ingest import fetch_alarm_logs
from diet_guard._device import device_id
from diet_guard._state import load_log, log_meal
from diet_guard._state_sync import read_raw_log, write_raw_log
from diet_guard._sync_banks import _primary_only_text
from diet_guard.sync_merge import daylog_to_log
from diet_guard.tests._sync_fakes import DictStore, _nutrition, _write_token

if TYPE_CHECKING:
    from pathlib import Path

_PRIVATE_MEAL = "secret oatmeal"
_OLD = "diet-guard-sync/devices"
_NEW = "diet-guard-sync/devices-e2e"


def _run(store: DictStore) -> None:
    _write_token()
    with patch.object(_sync_client, "GitHubSyncClient", return_value=store):
        _sync.run_sync()


def _peer_log(desc: str) -> str:
    """A plaintext food log a pre-E2E peer pushed, holding one meal."""
    log_meal(desc, _nutrition(), slot=480)
    log = daylog_to_log(read_raw_log())
    write_raw_log({})
    return json.dumps({rid: rec.to_dict() for rid, rec in log.items()})


def _all_meals() -> list[str]:
    return [entry["desc"] for entries in load_log().values() for entry in entries]


class TestSealedPush:
    def test_pushed_blobs_hold_no_plaintext(self) -> None:
        log_meal(_PRIVATE_MEAL, _nutrition(), slot=480)
        store = DictStore()
        _run(store)

        own = f"{_NEW}/{device_id()}"
        log_blob = store.files[f"{own}/food_log.json"]
        assert "secret" not in log_blob
        assert '"fields"' not in log_blob
        assert '"desc"' not in log_blob
        # Record ids stay clear by design (kuhy's call: ids, tombstones and
        # clocks are metadata). The food banks key records by food name, so
        # only their *fields* are asserted sealed here.
        for path, text in store.files.items():
            assert "kcal" not in text, path
            assert "protein" not in text, path

    def test_nothing_is_written_to_the_old_plaintext_prefix(self) -> None:
        log_meal(_PRIVATE_MEAL, _nutrition(), slot=480)
        store = DictStore()
        _run(store)

        assert store.puts
        for path in store.puts:
            assert not path.startswith(f"{_OLD}/"), path
            assert not path.startswith("diet-guard-sync/revs/"), path
        assert f"diet-guard-sync/revs-e2e/{device_id()}" in store.files
        assert "diet-guard-sync/e2e" in store.files

    def test_another_device_with_the_passphrase_reads_it_back(self) -> None:
        log_meal(_PRIVATE_MEAL, _nutrition(), slot=480)
        store = DictStore()
        _run(store)

        reader = _sync_e2e.open_e2e(store)
        text = reader.get_file_text(f"{_NEW}/{device_id()}/food_log.json")
        assert text is not None
        assert _PRIVATE_MEAL in text


class TestMigration:
    def test_old_plaintext_peer_log_is_copied_and_merged(self) -> None:
        peer = _peer_log("peer porridge")
        store = DictStore({f"{_OLD}/phone/food_log.json": peer})
        _run(store)

        assert "peer porridge" in _all_meals()
        # Copied under E2E, and the old node left exactly as it was.
        assert "porridge" not in store.files[f"{_NEW}/phone/food_log.json"]
        assert store.files[f"{_OLD}/phone/food_log.json"] == peer

    def test_old_plaintext_export_keys_move_under_e2e(self) -> None:
        key_b64 = "c2VjcmV0LWV4cG9ydC1rZXktYnl0ZXMtMzItbG9uZyE="
        keyring = {
            "kid1": {
                "id": "kid1",
                "fields": {"k": [key_b64, "2026-11-01T00:00:00.000Z-0000-phone"]},
                "deleted": False,
            }
        }
        old_path = f"{_OLD}/phone/export_keys.json"
        store = DictStore({old_path: json.dumps(keyring)})
        _run(store)

        sealed = store.files[f"{_NEW}/phone/export_keys.json"]
        assert key_b64 not in sealed
        assert store.files[old_path] == json.dumps(keyring)
        reader = _sync_e2e.open_e2e(store)
        assert key_b64 in (reader.get_file_text(f"{_NEW}/phone/export_keys.json") or "")


class TestLocked:
    def test_no_passphrase_fails_closed_without_any_write(self, tmp_path: Path) -> None:
        log_meal(_PRIVATE_MEAL, _nutrition(), slot=480)
        store = DictStore()
        missing = tmp_path / "no-such-password"
        with (
            patch.object(_sync_e2e, "PASSWORD_FILE", missing),
            pytest.raises(_sync.SyncError, match="locked"),
        ):
            _run(store)
        assert store.puts == []

    def test_wrong_passphrase_fails_closed(self, tmp_path: Path) -> None:
        store = DictStore()
        # Another device creates the header under the test passphrase.
        with patch.object(_sync_e2e, "E2E_STATE_DIR", tmp_path / "other-device"):
            _sync_e2e.open_e2e(store)
        store.puts.clear()
        other = tmp_path / "other-password"
        other.write_text("a different passphrase")
        with (
            patch.object(_sync_e2e, "PASSWORD_FILE", other),
            pytest.raises(_sync.SyncError, match="locked"),
        ):
            _run(store)
        assert store.puts == []

    def test_locked_pull_reports_a_reason_instead_of_raising(
        self, tmp_path: Path
    ) -> None:
        _write_token()
        with (
            patch.object(_sync_e2e, "PASSWORD_FILE", tmp_path / "none"),
            patch.object(_sync_client, "GitHubSyncClient", return_value=DictStore()),
        ):
            reason = _sync.pull_shared_log()
        assert reason is not None
        assert "locked" in reason

    def test_unreadable_header_is_locked(self) -> None:
        store = DictStore({"diet-guard-sync/e2e": "not a header"})
        with pytest.raises(_sync.SyncError, match="locked"):
            _run(store)


class TestUndecryptablePeer:
    def test_peer_sealed_under_another_key_is_skipped(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        log_meal("mine", _nutrition(), slot=480)
        layout = E2eLayout.of(_OLD)
        path = f"{_NEW}/stranger/food_log.json"
        record = {
            "id": "r1",
            "fields": {"desc": ["x", "2026-11-01T00:00:00.000Z-0000-s"]},
        }
        alien = seal_log_text(
            json.dumps({"r1": record}),
            E2eCipher(b"\x01" * 32),
            path=path,
        )
        store = DictStore({path: alien})
        with caplog.at_level(logging.WARNING):
            _run(store)
        assert layout.prefix == _NEW
        assert "skipping" in caplog.text
        assert _all_meals() == ["mine"]


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
