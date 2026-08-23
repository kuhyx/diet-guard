"""The locally cached half of the synced catering credential.

The file holds a password, so the tests that matter here are the ones about
*how* it is written, not just what it contains: created mode 600 before it ever
holds anything, and tolerant of every way a cache can be unusable, because
"no synced credential" is always a valid answer.
"""

from __future__ import annotations

import json
import stat
from typing import TYPE_CHECKING

import diet_guard._kuchnia_credential_store as store

if TYPE_CHECKING:
    from pathlib import Path

    import pytest

_EDITED = "2026-08-23T10:00:00+02:00"


def test_round_trips() -> None:
    """A written credential reads back unchanged."""
    store.write_synced_credential("me@example.com", "hunter2", _EDITED)
    assert store.read_synced_credential() == ("me@example.com", "hunter2", _EDITED)


def test_missing_file_reads_as_none() -> None:
    """An absent cache is "not configured", never an error."""
    assert store.read_synced_credential() is None


def test_written_file_is_mode_600() -> None:
    """A password must never be readable by other local users.

    ``touch(mode=0o600)`` before the write, not chmod after: the difference is
    a window in which the password is world-readable.
    """
    store.write_synced_credential("me@example.com", "hunter2", _EDITED)
    mode = store.KUCHNIA_SYNCED_CREDENTIAL_FILE.stat().st_mode
    assert not mode & stat.S_IRGRP
    assert not mode & stat.S_IROTH


def test_unreadable_cache_reads_as_none() -> None:
    """Corrupt JSON means "log in again", which is always a valid next step."""
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.write_text("{not json", encoding="utf-8")
    assert store.read_synced_credential() is None


def test_non_object_cache_reads_as_none() -> None:
    """Valid JSON of the wrong shape is still unusable."""
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.write_text("[1, 2]", encoding="utf-8")
    assert store.read_synced_credential() is None


def test_half_written_cache_reads_as_none() -> None:
    """A username with no password cannot log in, so it is not a credential."""
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.write_text(
        json.dumps({"username": "me@example.com"}), encoding="utf-8"
    )
    assert store.read_synced_credential() is None


def test_empty_strings_read_as_none() -> None:
    """Blank halves are the same as missing ones, not a usable credential."""
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.write_text(
        json.dumps({"username": "", "password": "", "t": _EDITED}), encoding="utf-8"
    )
    assert store.read_synced_credential() is None


def test_wrongly_typed_halves_read_as_none() -> None:
    """A peer running something odd cannot hand us a non-string password."""
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.write_text(
        json.dumps({"username": "me@example.com", "password": 42}), encoding="utf-8"
    )
    assert store.read_synced_credential() is None


def test_missing_edit_time_defaults_to_empty() -> None:
    """A cache without ``t`` is still usable; it just loses every LWW race."""
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    store.KUCHNIA_SYNCED_CREDENTIAL_FILE.write_text(
        json.dumps({"username": "me@example.com", "password": "hunter2"}),
        encoding="utf-8",
    )
    assert store.read_synced_credential() == ("me@example.com", "hunter2", "")


def test_unreadable_file_reads_as_none(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An OSError on read is warned about, not raised.

    ``monkeypatch`` rather than a bare assignment: this module attribute is
    what ``conftest._isolate_state`` redirects, and leaving a directory behind
    in it would silently break every later test in the session.
    """
    directory = tmp_path / "not_a_file.json"
    directory.mkdir()
    monkeypatch.setattr(store, "KUCHNIA_SYNCED_CREDENTIAL_FILE", directory)
    assert store.read_synced_credential() is None


def test_read_credentials_falls_back_to_the_synced_copy() -> None:
    """A device with no hand-written file still logs in from the synced copy.

    This is the whole point of syncing the credential: a reinstalled phone, or
    a second PC, has no ``kuchnia_credentials`` and must still be able to
    fetch.
    """
    from diet_guard._kuchnia_config import read_credentials

    store.write_synced_credential("synced@example.com", "synced-pass", _EDITED)
    assert read_credentials() == ("synced@example.com", "synced-pass")
