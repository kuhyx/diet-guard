"""The panel's CSRF handshake at login.

Since ~2026-10 the panel enforces Spring's CSRF check: a login without an
``X-XSRF-TOKEN`` header gets a bare 403 that also sets the ``XSRF-TOKEN``
cookie. The client retries once echoing it. Before this, every login failed
with "login rejected (HTTP 403)" whatever the password was.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from diet_guard import _kuchnia_client, _kuchnia_config
from diet_guard._kuchnia_client import PanelSession
from diet_guard._kuchnia_errors import KuchniaError
from diet_guard.tests._kuchnia_fakes import (
    FakeResponse,
    FakeSession,
    fake_requests,
    write_credentials,
)

_CSRF = "csrf-123"


@pytest.fixture(autouse=True)
def creds() -> None:
    """Write a credentials file at the (redirected) config path."""
    write_credentials(_kuchnia_config.KUCHNIA_CREDENTIALS_FILE)


def _csrf_403() -> FakeResponse:
    return FakeResponse(403, text="", cookies={"XSRF-TOKEN": _CSRF})


def _authenticate(session: FakeSession) -> None:
    with patch.object(_kuchnia_client, "requests", fake_requests(session)):
        PanelSession().authenticate()


def test_a_csrf_403_is_retried_echoing_the_token() -> None:
    session = FakeSession([_csrf_403(), FakeResponse(200, {})])
    _authenticate(session)
    assert [call[0] for call in session.calls] == ["POST", "POST"]
    assert "X-XSRF-TOKEN" not in session.sent_headers[0]
    assert session.sent_headers[1]["X-XSRF-TOKEN"] == _CSRF
    assert _kuchnia_config.load_session_cookie() == "session-abc"


def test_a_wrong_password_behind_csrf_still_names_the_password() -> None:
    session = FakeSession([_csrf_403(), FakeResponse(401, {})])
    with pytest.raises(KuchniaError, match=r"HTTP 401.*check the password"):
        _authenticate(session)


def test_a_second_403_blames_the_panel_not_the_password() -> None:
    session = FakeSession([_csrf_403(), _csrf_403()])
    with pytest.raises(KuchniaError, match="not a password problem") as raised:
        _authenticate(session)
    assert "HTTP 403" in str(raised.value)
    assert len(session.calls) == 2


def test_a_403_without_a_token_is_not_retried() -> None:
    session = FakeSession([FakeResponse(403, text="")])
    with pytest.raises(KuchniaError, match="not a password problem"):
        _authenticate(session)
    assert len(session.calls) == 1
