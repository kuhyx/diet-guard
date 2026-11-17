"""The relay opens the header diet_guard's own sync already wrote.

The contract rests on "same header, same key": the phone unlocks nothing new.
This builds the header the way production did (``open_encrypted_client`` over
the old devices prefix), hands its text to the relay's RTDB, and requires the
relay's sealer to read and write blobs the devices store's key opens.
"""

from __future__ import annotations

import asyncio

from crdt_sync import open_encrypted_client
from rtdb_relay.seal import Sealer
from rtdb_relay.tests._fake_rtdb import FakeRtdb

from diet_guard import _claude_connect, _sync_e2e
from diet_guard._claude_layout import LAYOUT
from diet_guard.tests._state_redirects import TEST_ARGON2, TEST_PHRASE


class _MemoryStore:
    """A dict-backed ``RemoteStore``: just enough for the key header."""

    def __init__(self) -> None:
        self.files: dict[str, str] = {}

    def list_directory(self, path: str) -> list[str]:
        del path
        return []

    def get_file_text(self, path: str) -> str | None:
        return self.files.get(path)

    def put_file_text(self, path: str, text: str, *, message: str) -> None:
        del message
        self.files[path] = text

    def delete_file(self, path: str, *, message: str = "") -> None:
        del message
        self.files.pop(path, None)

    def can_access_remote(self) -> bool:
        return True


def test_relay_unlocks_the_header_the_devices_store_wrote() -> None:
    """One header, one key: a blob either side seals opens on the other."""
    memory = _MemoryStore()
    devices, layout = open_encrypted_client(
        memory,
        _sync_e2e.LEGACY_DEVICES_DIR,
        passphrase=TEST_PHRASE,
        params=TEST_ARGON2,
    )
    header = memory.files[layout.e2e_path]
    fake = FakeRtdb(sealed=False)
    fake.raw_set(layout.e2e_path, header)

    rtdb = asyncio.run(_claude_connect.unlock_sealed(fake.rtdb()))

    assert fake.raw_get(layout.e2e_path) == header  # read, never rewritten
    assert rtdb.sealer is not None
    path = "requests/01J0000000000000000000000R/req"
    sealed = rtdb.sealer.seal(path, {"kind": "meal", "created": 5})
    devices_view = Sealer(devices.key.cipher(), LAYOUT)
    devices_view.root = rtdb.sealer.root
    assert devices_view.open(path, sealed) == {"kind": "meal", "created": 5}
