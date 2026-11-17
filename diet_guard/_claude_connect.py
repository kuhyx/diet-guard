"""Connecting the relay worker to RTDB, signed in and unlocked.

The database URL and API key come from crdt-sync's shared
``~/.config/crdt-sync/firebase.json``; the signed-in session is the worker's
own app, ``~/.config/diet_guard_claude/firebase_auth.json`` (seeded once with
crdt-sync's ``seed_session --app diet_guard_claude``). Never the gate's
``diet_guard`` session file: two processes refreshing one token file corrupt
it. Never ``firebase_client_for``: without a session it falls back to the
dead shared password and fails with a misleading error.

:func:`connect_sealed` is the worker's only network entry point besides the
event stream it returns; ``conftest`` blocks it.
"""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Final

from crdt_sync import (
    ConfigError,
    E2eLockedError,
    FirebaseAuthError,
    FirebaseConfig,
    FirebaseTokenProvider,
    credential_store_for,
)
from rtdb_relay.rtdb import Rtdb, RtdbError
from rtdb_relay.seal import Sealer
from rtdb_relay.unlock import unlock

from diet_guard import _sync_e2e
from diet_guard._claude_layout import E2E_LAYOUT, LAYOUT, ROOT

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable

APP: Final = "diet_guard_claude"


class RelaySetupError(RuntimeError):
    """The relay cannot start: no config, no session, or the key is locked."""


def token_source(provider: FirebaseTokenProvider) -> Callable[[], Awaitable[str]]:
    """An async id-token getter (the provider is sync and refreshes itself)."""

    async def token() -> str:
        try:
            return await asyncio.to_thread(provider.id_token)
        except FirebaseAuthError as err:
            msg = f"firebase auth failed: {err}"
            raise RtdbError(msg) from None

    return token


def connect() -> Rtdb:
    """An unsealed RTDB client rooted at the relay, signed in as the worker."""
    try:
        config = FirebaseConfig.load()
    except ConfigError as err:
        msg = f"no crdt-sync firebase config: {err}"
        raise RelaySetupError(msg) from err
    provider = FirebaseTokenProvider(config.api_key, credential_store_for(APP))
    if not provider.has_session():
        msg = (
            f"no signed-in session in ~/.config/{APP}/firebase_auth.json; seed it "
            f"with crdt-sync: python3 -m tool.seed_session ... --app {APP}"
        )
        raise RelaySetupError(msg)
    return Rtdb(config.database_url, token_source(provider), root=ROOT)


def passphrase() -> str:
    """The shared crdt-sync passphrase of this PC, or "" (locked)."""
    try:
        return _sync_e2e.PASSWORD_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


async def connect_sealed() -> Rtdb:
    """The test seam: the worker connects only through this name."""
    return await unlock_sealed(connect())


async def unlock_sealed(rtdb: Rtdb) -> Rtdb:
    """Unlock ``rtdb``: everything it writes is sealed from now on.

    Raises:
        RelaySetupError: The e2e key is locked or unreachable. Nothing may be
            read or written (fail closed).
    """
    try:
        key = await unlock(rtdb, passphrase(), E2E_LAYOUT, _sync_e2e.ARGON2_PARAMS)
    except (E2eLockedError, RtdbError) as err:
        await rtdb.aclose()
        msg = f"e2e locked or unreachable ({err})"
        raise RelaySetupError(msg) from err
    rtdb.sealer = Sealer(key.cipher(), LAYOUT)
    return rtdb
