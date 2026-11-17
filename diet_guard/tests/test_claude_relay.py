"""Connecting, unlocking, the serve loop and the CLI entry of the relay worker."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import TYPE_CHECKING
from unittest.mock import AsyncMock, Mock, patch

from crdt_sync import ConfigError, FirebaseAuthError
import pytest
from rtdb_relay.rtdb import RtdbError
from rtdb_relay.sse import StreamCancelledError
from rtdb_relay.tests._fake_rtdb import FakeRtdb

from diet_guard import _claude_connect as connect_mod
from diet_guard import _claude_relay as relay
from diet_guard import _claude_sync, _sync_e2e
from diet_guard._claude_layout import LAYOUT, ROOT
from diet_guard._cli import main as cli_main
from diet_guard.tests._claude_fakes import fresh

if TYPE_CHECKING:
    from pathlib import Path

CONFIG = SimpleNamespace(api_key="key", database_url="https://db.test")


def _provider(*, session: bool = True, token: str | Exception = "tok") -> Mock:
    provider = Mock()
    provider.has_session.return_value = session
    if isinstance(token, Exception):
        provider.id_token.side_effect = token
    else:
        provider.id_token.return_value = token
    return provider


# -- connect --------------------------------------------------------------------
def test_connect_builds_a_client_rooted_at_the_relay() -> None:
    """Config and the sync's session give an Rtdb on the relay root."""
    provider = _provider()
    with (
        patch.object(connect_mod.FirebaseConfig, "load", return_value=CONFIG),
        patch.object(connect_mod, "FirebaseTokenProvider", return_value=provider),
        patch.object(connect_mod, "credential_store_for") as store,
    ):
        rtdb = connect_mod.connect()
    store.assert_called_once_with("diet_guard")
    assert rtdb.root == ROOT
    assert rtdb.sealer is None


def test_connect_without_firebase_config_is_a_setup_error() -> None:
    """No crdt-sync config: nothing to connect to."""
    with (
        patch.object(connect_mod.FirebaseConfig, "load", side_effect=ConfigError("x")),
        pytest.raises(
            connect_mod.RelaySetupError, match="no crdt-sync firebase config"
        ),
    ):
        connect_mod.connect()


def test_connect_without_a_session_names_the_session_file() -> None:
    """No signed-in session: the error says where the sync's session lives."""
    with (
        patch.object(connect_mod.FirebaseConfig, "load", return_value=CONFIG),
        patch.object(connect_mod, "credential_store_for"),
        patch.object(
            connect_mod, "FirebaseTokenProvider", return_value=_provider(session=False)
        ),
        pytest.raises(
            connect_mod.RelaySetupError,
            match=r"~/.config/diet_guard/firebase_auth.json",
        ),
    ):
        connect_mod.connect()


def test_token_source_wraps_auth_errors_without_the_secret() -> None:
    """An auth failure becomes an RtdbError; a good token passes through."""

    async def go() -> str:
        good = connect_mod.token_source(_provider())
        bad = connect_mod.token_source(_provider(token=FirebaseAuthError("secret")))
        with pytest.raises(RtdbError, match="firebase auth failed"):
            await bad()
        return await good()

    assert asyncio.run(go()) == "tok"


def test_connect_sealed_is_connect_then_unlock() -> None:
    """The seam is a thin wrapper over the two real steps."""
    real = fresh(connect_mod)
    rtdb = object()
    with (
        patch.object(real, "connect", return_value=rtdb),
        patch.object(real, "unlock_sealed", AsyncMock(return_value="sealed")) as unlock,
    ):
        assert asyncio.run(real.connect_sealed()) == "sealed"
    unlock.assert_awaited_once_with(rtdb)


# -- unlock ---------------------------------------------------------------------
def test_unlock_seals_with_the_existing_header_key() -> None:
    """The header is diet_guard's own (made once); a second unlock gets the same key."""
    fake = FakeRtdb(sealed=False)
    first = asyncio.run(connect_mod.unlock_sealed(fake.rtdb()))
    assert fake.raw_get("diet-guard-sync/e2e") is not None
    second = asyncio.run(connect_mod.unlock_sealed(fake.rtdb()))
    assert first.sealer is not None
    assert second.sealer is not None
    first.sealer.root = second.sealer.root = ROOT
    sealed = first.sealer.seal("requests/R/req", {"a": 1})
    assert second.sealer.open("requests/R/req", sealed) == {"a": 1}
    assert first.sealer.layout is LAYOUT


@pytest.mark.parametrize("phrase", ["", "the-wrong-phrase"])
def test_unlock_with_no_or_a_wrong_passphrase_fails_closed(
    phrase: str, tmp_path: Path
) -> None:
    """A locked key raises RelaySetupError and leaves the client unsealed."""
    fake = FakeRtdb(sealed=False)
    asyncio.run(
        connect_mod.unlock_sealed(fake.rtdb())
    )  # header made with the test phrase
    file = tmp_path / "other-phrase"
    file.write_text(phrase, encoding="utf-8")
    rtdb = fake.rtdb()
    with (
        patch.object(_sync_e2e, "PASSWORD_FILE", file),
        pytest.raises(connect_mod.RelaySetupError, match="e2e locked"),
    ):
        asyncio.run(connect_mod.unlock_sealed(rtdb))


def test_missing_password_file_reads_as_locked(tmp_path: Path) -> None:
    """No password file: an empty passphrase, which unlock refuses."""
    with patch.object(_sync_e2e, "PASSWORD_FILE", tmp_path / "absent"):
        assert connect_mod.passphrase() == ""
    assert connect_mod.passphrase() == "test-passphrase"


# -- sync touch points ----------------------------------------------------------
def test_sync_touch_points_call_the_real_helpers() -> None:
    """pull_peers and publish forward to the narrow pull and the full tick."""
    real = fresh(_claude_sync)
    with (
        patch("diet_guard._sync_refresh.pull_peer_logs", return_value="x") as pull,
        patch("diet_guard._sync_events.publish_after_log", return_value=None) as pub,
    ):
        assert real.pull_peers() == "x"
        assert real.publish() is None
    pull.assert_called_once_with()
    pub.assert_called_once_with()


# -- the serve loop and the CLI -------------------------------------------------
class _StopError(Exception):
    """Ends the serve loop in a test."""


def test_serve_waits_and_retries_while_the_relay_cannot_start() -> None:
    """A setup failure writes nothing, sleeps 60 s and tries again."""
    rtdb = Mock(aclose=AsyncMock())
    waits: list[float] = []

    async def sleep(seconds: float) -> None:
        waits.append(seconds)

    async def go() -> None:
        with (
            patch.object(
                connect_mod,
                "connect_sealed",
                AsyncMock(side_effect=[connect_mod.RelaySetupError("locked"), rtdb]),
            ),
            patch.object(relay.MealServer, "run", AsyncMock(side_effect=_StopError)),
            pytest.raises(_StopError),
        ):
            await relay.serve(sleep)

    asyncio.run(go())
    assert waits == [relay.RETRY_S]
    rtdb.aclose.assert_awaited_once_with()


@pytest.mark.parametrize(
    ("raised", "code"),
    [(None, 0), (KeyboardInterrupt(), 0), (StreamCancelledError("rules"), 1)],
)
def test_main_exit_codes(raised: BaseException | None, code: int) -> None:
    """Clean stop and Ctrl-C exit 0; a cancelled stream exits 1 (systemd restarts)."""
    with patch.object(relay, "serve", AsyncMock(side_effect=raised)):
        assert relay.main() == code


def test_cli_dispatches_claude_worker_lazily() -> None:
    """The subcommand imports the worker only when it runs, and returns its code."""
    with patch.object(relay, "main", return_value=7):
        assert cli_main(["claude-worker"]) == 7
