"""The credential's pull/merge/push tick.

The behaviours worth pinning are the ones whose failure is silent:

* the hand-written file **bootstraps** the first push (without it the PC never
  publishes, so the phone never receives and the whole feature is dead),
* an unchanged credential is **not** rewritten every tick, and
* an unparsable peer file is skipped rather than taking out the tick.
"""

from __future__ import annotations

import json
from typing import TYPE_CHECKING
from unittest.mock import MagicMock

from crdt_sync import Hlc, Record

import diet_guard._kuchnia_credential_store as store
from diet_guard._sync_kuchnia import _local_credential_log, _sync_kuchnia_credential
from diet_guard.sync_merge._kuchnia import (
    KUCHNIA_RECORD_ID,
    PASSWORD_FIELD_NAME,
    USERNAME_FIELD_NAME,
)

if TYPE_CHECKING:
    import pytest

_EDITED = "2026-08-23T10:00:00+02:00"


def _client(files: dict[str, str] | None = None) -> MagicMock:
    """A sync client that serves ``files`` and records every push."""
    client = MagicMock()
    client.get_file_text.side_effect = (files or {}).get
    return client


def _peer_push(username: str, password: str, wall_ms: int) -> str:
    """Serialize a credential as a peer device would have pushed it."""
    hlc = Hlc.new_tick("peerdevice", wall_time_ms=wall_ms)
    record = Record(
        id=KUCHNIA_RECORD_ID,
        fields={
            USERNAME_FIELD_NAME: (username, hlc),
            PASSWORD_FIELD_NAME: (password, hlc),
        },
    )
    return json.dumps({KUCHNIA_RECORD_ID: record.to_dict()})


def _write_handwritten(text: str) -> None:
    """Write the user's hand-maintained credentials file."""
    from diet_guard import _kuchnia_config

    path = _kuchnia_config.KUCHNIA_CREDENTIALS_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def test_no_credential_anywhere_pushes_nothing() -> None:
    """An unconfigured device must not publish an empty credential."""
    client = _client()
    _sync_kuchnia_credential(client, ["phone"])
    client.put_file_text.assert_not_called()


def test_the_handwritten_file_bootstraps_the_first_push() -> None:
    """The PC is where the password is typed, so it must be what publishes.

    Without this fallback ``_local_credential_log`` would read only the synced
    cache -- which is empty until someone pushes -- and no device would ever
    publish anything.
    """
    _write_handwritten("me@example.com\nhunter2\n")
    client = _client()
    _sync_kuchnia_credential(client, [])

    client.put_file_text.assert_called_once()
    pushed = json.loads(client.put_file_text.call_args.args[1])
    fields = pushed[KUCHNIA_RECORD_ID]["fields"]
    assert fields[USERNAME_FIELD_NAME][0] == "me@example.com"
    assert fields[PASSWORD_FIELD_NAME][0] == "hunter2"


def test_a_peer_credential_is_cached_locally() -> None:
    """Receiving a peer's credential is what makes a wiped device work again."""
    client = _client(
        {
            "diet-guard-sync/devices/phone/kuchnia.json": _peer_push(
                "peer@example.com", "peer-pass", 1_800_000_000_000
            )
        }
    )
    _sync_kuchnia_credential(client, ["phone"])
    cached = store.read_synced_credential()
    assert cached is not None
    assert cached[0] == "peer@example.com"
    assert cached[1] == "peer-pass"


def test_an_unchanged_credential_is_not_rewritten() -> None:
    """Re-running the tick must not rewrite the file every time."""
    client = _client(
        {
            "diet-guard-sync/devices/phone/kuchnia.json": _peer_push(
                "peer@example.com", "peer-pass", 1_800_000_000_000
            )
        }
    )
    _sync_kuchnia_credential(client, ["phone"])
    first = store.KUCHNIA_SYNCED_CREDENTIAL_FILE.stat().st_mtime_ns

    _sync_kuchnia_credential(client, ["phone"])
    assert store.KUCHNIA_SYNCED_CREDENTIAL_FILE.stat().st_mtime_ns == first


def test_an_unparsable_peer_file_is_skipped(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """One bad peer file must not take out the tick for every other device."""
    client = _client(
        {
            "diet-guard-sync/devices/bad/kuchnia.json": "{not json",
            "diet-guard-sync/devices/phone/kuchnia.json": _peer_push(
                "peer@example.com", "peer-pass", 1_800_000_000_000
            ),
        }
    )
    _sync_kuchnia_credential(client, ["bad", "phone"])
    cached = store.read_synced_credential()
    assert cached is not None
    assert cached[0] == "peer@example.com"
    assert "Unparsable catering credential" in caplog.text


def test_a_missing_peer_file_is_skipped() -> None:
    """A device that has never pushed a credential contributes nothing."""
    client = _client()
    _write_handwritten("me@example.com\nhunter2\n")
    _sync_kuchnia_credential(client, ["phone"])
    client.get_file_text.assert_called_once_with(
        "diet-guard-sync/devices/phone/kuchnia.json"
    )


def test_the_synced_cache_wins_over_the_handwritten_file() -> None:
    """Once a merge has resolved, that is what this device contributes.

    Otherwise the hand-written file -- a deliberately *local* override -- would
    be republished to every peer on every tick.
    """
    store.write_synced_credential("synced@example.com", "synced-pass", _EDITED)
    _write_handwritten("local@example.com\nlocal-pass\n")
    log = _local_credential_log()
    assert log[KUCHNIA_RECORD_ID].fields[USERNAME_FIELD_NAME][0] == "synced@example.com"


def test_a_malformed_handwritten_file_contributes_nothing() -> None:
    """A one-line credentials file is unusable, not a crash."""
    _write_handwritten("only-a-username\n")
    assert _local_credential_log() == {}


def test_no_handwritten_file_and_no_cache_contributes_nothing() -> None:
    """A device that has never seen the password contributes an empty log.

    Distinct from the malformed-file case below: here the file is absent
    entirely, which is the normal state of a freshly installed second device.
    """
    assert _local_credential_log() == {}
