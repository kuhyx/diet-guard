"""End-to-end encryption of every payload this app syncs.

Every blob under ``diet-guard-sync/devices-e2e`` is sealed with a key derived
(Argon2id) from the shared crdt-sync passphrase in
``~/.config/crdt-sync/password``; Firebase and the GitHub mirror only ever see
record ids, tombstones and clocks. The wake-alarm weigh-ins this app reads
live on their own prefix (``wake-alarm-sync/devices-e2e``) with their own
header, hence a second store over the same raw backend.

Fail closed: no passphrase, a wrong one or an unreadable header raises
:class:`~crdt_sync.E2eLockedError` and nothing is pulled or pushed -- never a
plaintext fallback.

The old plaintext prefix is copied over (and never deleted) while a device
not yet migrated may still write it; see :func:`open_e2e` for when.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from crdt_sync import (
    PASSWORD_FILE,
    E2eDecryptError,
    E2eLayout,
    E2eLockedError,
    EncryptingStore,
    MirrorSyncClient,
    open_encrypted_client,
)

from diet_guard._constants import E2E_STATE_DIR

if TYPE_CHECKING:
    from crdt_sync import Argon2Params, E2eKey, RemoteStore

_logger = logging.getLogger(__name__)

#: The plaintext prefix every pre-E2E build wrote; read only by the copy.
LEGACY_DEVICES_DIR = "diet-guard-sync/devices"

#: Where the wake-alarm app published before E2E.
LEGACY_WAKE_ALARM_DIR = "wake-alarm-sync/devices"

DIET_LAYOUT = E2eLayout.of(LEGACY_DEVICES_DIR)
WAKE_ALARM_LAYOUT = E2eLayout.of(LEGACY_WAKE_ALARM_DIR)

#: Argon2id cost for a header this device creates; None is the library's
#: default. Only tests lower it.
ARGON2_PARAMS: Argon2Params | None = None


class E2eStore(EncryptingStore):
    """An :class:`EncryptingStore` that remembers the backend it wraps.

    The raw backend is what a second prefix (wake-alarm) is opened over, and
    its Firebase half is what the primary-only reads go to.
    """

    def __init__(self, raw: RemoteStore, key: E2eKey, layout: E2eLayout) -> None:
        """Wrap ``raw`` for ``layout``, sealing with ``key``."""
        super().__init__(raw, key, layout)
        self.raw = raw
        self.layout = layout

    def primary_only(self) -> EncryptingStore:
        """The same encryption over the Firebase half alone (no mirror)."""
        raw = self.raw
        inner = raw.primary if isinstance(raw, MirrorSyncClient) else raw
        return EncryptingStore(inner, self.key, self.layout)


def _read_passphrase() -> str:
    """The shared crdt-sync passphrase, or "" when this machine has none."""
    try:
        return PASSWORD_FILE.read_text().strip()
    except OSError:
        return ""


def open_e2e(raw: RemoteStore, old_prefix: str = LEGACY_DEVICES_DIR) -> E2eStore:
    """Unlock ``old_prefix``'s encrypted twin over ``raw``.

    diet_guard's own prefix keeps its derived key and copy memo in
    :data:`E2E_STATE_DIR`, so a fresh gate process neither re-runs Argon2id
    nor re-reads every old blob. The wake-alarm prefix does not: its phone
    publishes no revisions, so a persisted memo would never see a phone not
    yet migrated write a new alarm, and the copy reruns once per process.

    Raises:
        E2eLockedError: No passphrase, a wrong one, an unreadable header, or
            a copy that met a blob it cannot open.
    """
    # An empty passphrase still opens with diet_guard's cached key; without
    # one the library raises E2eLockedError.
    passphrase = _read_passphrase()
    state_dir = E2E_STATE_DIR if old_prefix == LEGACY_DEVICES_DIR else None
    try:
        store, layout = open_encrypted_client(
            raw,
            old_prefix,
            passphrase=passphrase,
            params=ARGON2_PARAMS,
            state_dir=state_dir,
        )
    except E2eDecryptError as exc:
        raise E2eLockedError(str(exc)) from exc
    return E2eStore(raw, store.key, layout)


def read_sealed(store: RemoteStore, path: str) -> str | None:
    """``store.get_file_text``, with an undecryptable blob treated as absent.

    A peer sealed under another key, tampered with, or written by a newer
    format is skipped (and so retried next tick), never fatal: one bad peer
    must not stall the merge of every other one.
    """
    try:
        return store.get_file_text(path)
    except E2eDecryptError as exc:
        _logger.warning("e2e: skipping %s: %s", path, exc)
        return None
