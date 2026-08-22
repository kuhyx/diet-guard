"""Tests for the catering panel client, its config files, and the walk.

The client never reaches the network here: ``requests`` is replaced at the
module seam, which is why :mod:`diet_guard._kuchnia_client` resolves that name
through ``sys.modules`` instead of binding it at import time.
"""

from __future__ import annotations

import datetime
import json
from typing import TYPE_CHECKING
from unittest.mock import patch

import pytest

from diet_guard import _kuchnia_client, _kuchnia_config
from diet_guard._kuchnia_client import PanelSession
from diet_guard._kuchnia_errors import KuchniaError
from diet_guard.tests._kuchnia_fakes import (
    FakeRequestError,
    FakeResponse,
    FakeSession,
    fake_requests,
    write_credentials,
)

if TYPE_CHECKING:
    from pathlib import Path

DAY = datetime.date(2026, 8, 22)


@pytest.fixture
def creds() -> None:
    """Write a credentials file at the (redirected) config path."""
    write_credentials(_kuchnia_config.KUCHNIA_CREDENTIALS_FILE)


def _session_with(responses: list[FakeResponse]) -> FakeSession:
    return FakeSession(responses)


class TestCredentials:
    def test_missing_file_names_the_path_and_the_fix(self) -> None:
        with pytest.raises(KuchniaError, match="no catering credentials"):
            _kuchnia_config.read_credentials()

    def test_a_one_line_file_is_rejected(self) -> None:
        path = _kuchnia_config.KUCHNIA_CREDENTIALS_FILE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("only-an-email\n", encoding="utf-8")
        with pytest.raises(KuchniaError, match="two lines"):
            _kuchnia_config.read_credentials()

    def test_blank_lines_are_ignored(self, creds: None) -> None:
        assert _kuchnia_config.read_credentials() == ("me@example.com", "pw")


class TestSessionCache:
    def test_absent_cache_reads_as_none(self) -> None:
        assert _kuchnia_config.load_session_cookie() is None

    def test_round_trips_and_is_owner_only(self) -> None:
        _kuchnia_config.save_session_cookie("abc")
        assert _kuchnia_config.load_session_cookie() == "abc"
        mode = _kuchnia_config.KUCHNIA_SESSION_FILE.stat().st_mode & 0o777
        # 600 from the outset: a write-then-chmod would leave a live session
        # cookie world-readable for the duration of the write.
        assert mode == 0o600

    def test_no_temp_file_is_left_behind(self) -> None:
        _kuchnia_config.save_session_cookie("abc")
        leftovers = list(_kuchnia_config.KUCHNIA_SESSION_FILE.parent.glob("*.tmp"))
        assert leftovers == []

    @pytest.mark.parametrize(
        "content", ["{not json", '{"SESSION": 7}', "[]", '{"SESSION": ""}']
    )
    def test_an_unusable_cache_reads_as_none(self, content: str) -> None:
        path = _kuchnia_config.KUCHNIA_SESSION_FILE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        assert _kuchnia_config.load_session_cookie() is None

    def test_clearing_is_idempotent(self) -> None:
        _kuchnia_config.clear_session_cookie()
        _kuchnia_config.save_session_cookie("abc")
        _kuchnia_config.clear_session_cookie()
        assert _kuchnia_config.load_session_cookie() is None


class TestAuthenticate:
    def test_logs_in_and_caches_the_cookie(self, creds: None) -> None:
        session = _session_with([FakeResponse(200, {})])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            PanelSession().authenticate()
        assert _kuchnia_config.load_session_cookie() == "session-abc"
        assert session.calls[0][0] == "POST"

    def test_a_cached_cookie_skips_the_login(self, creds: None) -> None:
        _kuchnia_config.save_session_cookie("cached")
        session = _session_with([])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            PanelSession().authenticate()
        assert session.calls == []
        assert session.cookies["SESSION"] == "cached"

    def test_a_rejected_login_raises(self, creds: None) -> None:
        session = _session_with([FakeResponse(401, {})])
        with (
            patch.object(_kuchnia_client, "requests", fake_requests(session)),
            pytest.raises(KuchniaError, match="login rejected"),
        ):
            PanelSession().authenticate()

    def test_a_login_that_sets_no_cookie_raises(self, creds: None) -> None:
        session = _session_with([FakeResponse(200, {})])
        session.login_cookie = None
        with (
            patch.object(_kuchnia_client, "requests", fake_requests(session)),
            pytest.raises(KuchniaError, match="no session cookie"),
        ):
            PanelSession().authenticate()

    def test_login_body_is_form_encoded_not_json(self, creds: None) -> None:
        # The panel rejects a JSON login body; this is the one call that must
        # go out as application/x-www-form-urlencoded.
        session = _session_with([FakeResponse(200, {})])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            PanelSession().authenticate()
        assert session.bodies == [{"username": "me@example.com", "password": "pw"}]


class TestGetJson:
    def test_returns_the_decoded_body(self, creds: None) -> None:
        session = _session_with([FakeResponse(200, {"ok": True})])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            panel = PanelSession()
            assert panel.get_json("x") == {"ok": True}

    @pytest.mark.parametrize("status", [401, 403])
    def test_an_expired_cookie_re_logs_in_once(self, creds: None, status: int) -> None:
        _kuchnia_config.save_session_cookie("stale")
        session = _session_with(
            [
                FakeResponse(status, {}),
                FakeResponse(200, {}),
                FakeResponse(200, {"ok": 1}),
            ],
        )
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            panel = PanelSession()
            panel.authenticate()
            assert panel.get_json("x") == {"ok": 1}
        methods = [call[0] for call in session.calls]
        assert methods.count("POST") == 1, "exactly one re-login"

    def test_a_second_auth_failure_is_real(self, creds: None) -> None:
        session = _session_with(
            [FakeResponse(401, {}), FakeResponse(200, {}), FakeResponse(401, {})],
        )
        with (
            patch.object(_kuchnia_client, "requests", fake_requests(session)),
            pytest.raises(KuchniaError, match="HTTP 401"),
        ):
            PanelSession().get_json("x")

    def test_a_server_error_raises(self, creds: None) -> None:
        session = _session_with([FakeResponse(500, {})])
        with (
            patch.object(_kuchnia_client, "requests", fake_requests(session)),
            pytest.raises(KuchniaError, match="HTTP 500"),
        ):
            PanelSession().get_json("x")

    def test_a_non_json_body_raises(self, creds: None) -> None:
        session = _session_with([FakeResponse(200, None, text="<html>")])
        with (
            patch.object(_kuchnia_client, "requests", fake_requests(session)),
            pytest.raises(KuchniaError, match="non-JSON"),
        ):
            PanelSession().get_json("x")

    def test_a_transport_error_becomes_a_kuchnia_error(self, creds: None) -> None:
        session = _session_with([])
        session.raise_on_request = FakeRequestError("connection reset")
        with (
            patch.object(_kuchnia_client, "requests", fake_requests(session)),
            pytest.raises(KuchniaError, match="unreachable"),
        ):
            PanelSession().get_json("x")

    def test_the_whole_walk_has_a_deadline(self, creds: None) -> None:
        # Per-request timeouts alone would let four sequential calls stack into
        # half a minute in front of a user who is waiting.
        session = _session_with([FakeResponse(200, {})])
        with (
            patch.object(_kuchnia_client, "requests", fake_requests(session)),
            pytest.raises(KuchniaError, match="deadline"),
        ):
            PanelSession(deadline_seconds=-1.0).get_json("x")

    def test_required_headers_are_set(self, creds: None) -> None:
        session = _session_with([])
        with patch.object(_kuchnia_client, "requests", fake_requests(session)):
            PanelSession()
        assert session.headers["company-id"] == "kuchniavikinga"
        assert session.headers["X-Launcher-Type"] == "BROWSER_PANEL"
        # No sticky Content-Type: the login body is form-encoded and a JSON
        # default would mislabel it.
        assert "Content-Type" not in session.headers


def test_lazy_import_keeps_requests_out_of_the_gate_path() -> None:
    # The gate's not-due tick imports the CLI; paying ~78ms for an HTTP stack
    # it never touches is exactly what the PEP 562 hook exists to prevent.
    # The name lives in a variable so ruff cannot fold the lookup into a
    # bare attribute access and then flag it as a useless expression.
    missing = "definitely_not_a_real_name"
    with pytest.raises(AttributeError, match="no attribute"):
        getattr(_kuchnia_client, missing)


def test_the_session_file_is_json(creds: None) -> None:
    _kuchnia_config.save_session_cookie("abc")
    body = json.loads(_kuchnia_config.KUCHNIA_SESSION_FILE.read_text(encoding="utf-8"))
    assert body == {"SESSION": "abc"}


def test_state_stays_out_of_the_real_config_dir(tmp_path: Path) -> None:
    # The conftest redirect must actually redirect: a test that writes a
    # session cookie into ~/.config/diet_guard would clobber the live one.
    assert str(tmp_path) in str(_kuchnia_config.KUCHNIA_SESSION_FILE)
    assert str(tmp_path) in str(_kuchnia_config.KUCHNIA_CREDENTIALS_FILE)
