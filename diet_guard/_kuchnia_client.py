"""HTTP access to the Kuchnia Wikinga panel.

Auth is a cookie session, not a bearer token: ``POST auth/login`` with a
**form-urlencoded** body sets a ``SESSION`` cookie that every later call
carries.  The cookie is cached (:mod:`diet_guard._kuchnia_config`) so a refresh
normally skips the login round trip entirely, and an expired cookie costs one
extra request rather than a failed import.

``requests`` is imported lazily.  The gate's not-due tick imports the CLI and
must not pay ~78ms for an HTTP stack it never touches -- the same reason
:mod:`diet_guard._estimator_off` and :mod:`diet_guard._cli_prune` defer theirs.
Call sites reach through ``sys.modules[__name__]`` so a test's ``patch.object``
still wins over the lazy hook.
"""

from __future__ import annotations

from importlib import import_module
import sys
import time
from typing import TYPE_CHECKING

from diet_guard._constants import (
    KUCHNIA_API_BASE,
    KUCHNIA_COMPANY,
    KUCHNIA_LAUNCHER_TYPE,
    KUCHNIA_TIMEOUT_SECONDS,
    KUCHNIA_TOTAL_DEADLINE_SECONDS,
)
from diet_guard._kuchnia_config import (
    SESSION_COOKIE,
    clear_session_cookie,
    load_session_cookie,
    read_credentials,
    save_session_cookie,
)
from diet_guard._kuchnia_errors import KuchniaError

if TYPE_CHECKING:  # pragma: no cover - typing only
    import requests

_LAZY_ATTRS = ("requests",)

_COOKIE_DOMAIN = "panel.kuchniavikinga.pl"


def __getattr__(name: str) -> object:
    """Resolve the deferred ``requests`` import on first attribute access."""
    if name not in _LAZY_ATTRS:
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    return import_module(name)


class PanelSession:
    """A logged-in panel session with a whole-walk deadline.

    The deadline exists because the import is several sequential requests: a
    per-request timeout alone would let a slow provider stack them into half a
    minute, and this runs on paths a user is waiting on.
    """

    def __init__(
        self, deadline_seconds: float = KUCHNIA_TOTAL_DEADLINE_SECONDS
    ) -> None:
        """Build an unauthenticated session with the panel's required headers."""
        module = sys.modules[__name__]
        self._session = module.requests.Session()
        # No session-level Content-Type: the login body is form-urlencoded and
        # a sticky JSON default would mislabel it. ``requests`` sets it per call.
        self._session.headers.update(
            {
                "company-id": KUCHNIA_COMPANY,
                "X-Launcher-Type": KUCHNIA_LAUNCHER_TYPE,
                "User-Agent": "diet_guard/1.0 (personal diet tracker)",
                "Accept": "application/json",
            },
        )
        self._expires_at = time.monotonic() + deadline_seconds

    def _check_deadline(self) -> None:
        """Raise once the whole-walk budget is spent."""
        if time.monotonic() >= self._expires_at:
            msg = "catering panel too slow (deadline exceeded)"
            raise KuchniaError(msg)

    def _request(
        self,
        method: str,
        path: str,
        data: dict[str, str] | None = None,
    ) -> requests.Response:
        """Perform one request, translating transport errors into KuchniaError.

        ``data`` is the only body this client ever sends (the form-urlencoded
        login), so it is spelled out rather than taken as ``**kwargs`` -- a
        concrete signature types better and keeps the surface honest.
        """
        self._check_deadline()
        module = sys.modules[__name__]
        try:
            return self._session.request(
                method,
                f"{KUCHNIA_API_BASE}/{path}",
                timeout=KUCHNIA_TIMEOUT_SECONDS,
                data=data,
            )
        except module.requests.RequestException as exc:
            msg = f"catering panel unreachable: {exc}"
            raise KuchniaError(msg) from exc

    def _login(self) -> None:
        """Authenticate with the stored credentials and cache the cookie."""
        username, password = read_credentials()
        response = self._request(
            "POST",
            "auth/login",
            data={"username": username, "password": password},
        )
        if not response.ok:
            msg = f"catering login rejected (HTTP {response.status_code})"
            raise KuchniaError(msg)
        cookie = self._session.cookies.get(SESSION_COOKIE)
        if cookie is None:
            msg = "catering login returned no session cookie"
            raise KuchniaError(msg)
        save_session_cookie(cookie)

    def authenticate(self) -> None:
        """Attach the cached cookie, logging in only when there is not one."""
        cached = load_session_cookie()
        if cached is None:
            self._login()
            return
        self._session.cookies.set(SESSION_COOKIE, cached, domain=_COOKIE_DOMAIN)

    def get_json(self, path: str) -> object:
        """GET ``path`` and decode it, re-logging in once if the cookie expired.

        A cached cookie that has expired is indistinguishable from a good one
        until it is used, so an auth failure is retried exactly once with fresh
        credentials. A second failure is real.

        Args:
            path: Path below the API base, without a leading slash.

        Returns:
            The decoded JSON body.

        Raises:
            KuchniaError: On a non-OK status or an undecodable body.
        """
        response = self._request("GET", path)
        if response.status_code in {401, 403}:
            clear_session_cookie()
            self._login()
            response = self._request("GET", path)
        if not response.ok:
            msg = f"catering panel returned HTTP {response.status_code} for {path}"
            raise KuchniaError(msg)
        try:
            return response.json()
        except ValueError as exc:
            msg = f"catering panel returned a non-JSON body for {path}"
            raise KuchniaError(msg) from exc
