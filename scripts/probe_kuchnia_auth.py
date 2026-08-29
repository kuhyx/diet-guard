#!/usr/bin/env python3
"""Log in once and reuse the session across probe runs.

Typing an e-mail and password on every probe invocation is not just tedious --
it is the thing the real importer must never do either, so the cache is built
here and carried over to ``diet_guard._kuchnia_config`` rather than invented
twice.

Two files, both mode 600, both under ``~/.config/diet_guard/`` (outside the
synced ``~/.local/share`` tree, because a credential must not sync):

* ``kuchnia_credentials`` -- optional, **written by the user by hand**, two
  lines: e-mail then password.  Nothing here ever writes it; that mirrors
  ``sync_token``, which the package also only ever reads.
* ``kuchnia_session.json`` -- the cached ``SESSION`` cookie, written by this
  module.

The cache is created with ``touch(mode=0o600)`` *before* any content is
written, then atomically replaced -- writing first and chmod'ing after would
leave a live session cookie world-readable for the gap in between.
"""

from __future__ import annotations

import getpass
import json
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import requests

CONFIG_DIR = Path.home() / ".config" / "diet_guard"
CREDENTIALS_FILE = CONFIG_DIR / "kuchnia_credentials"
SESSION_FILE = CONFIG_DIR / "kuchnia_session.json"

#: The only cookie the panel issued on the first probe. No ``XSRF-TOKEN`` was
#: set, so the CSRF echo the bundles perform is a no-op for this account.
SESSION_COOKIE = "SESSION"


def read_credentials() -> tuple[str, str] | None:
    """Return ``(username, password)`` from the hand-written file, if present.

    Returns:
        The credentials, or None when the file is absent or malformed.
    """
    if not CREDENTIALS_FILE.exists():
        return None
    lines = [
        line.strip()
        for line in CREDENTIALS_FILE.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    expected = 2
    if len(lines) < expected:
        return None
    return lines[0], lines[1]


def load_session_cookie() -> str | None:
    """Return the cached session cookie, or None when there is no usable cache."""
    if not SESSION_FILE.exists():
        return None
    try:
        cached = json.loads(SESSION_FILE.read_text(encoding="utf-8"))
    except OSError, json.JSONDecodeError:
        return None
    value = cached.get(SESSION_COOKIE) if isinstance(cached, dict) else None
    return value if isinstance(value, str) else None


def save_session_cookie(value: str) -> None:
    """Persist ``value`` as the cached session cookie, mode 600 from the outset."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    temp = SESSION_FILE.with_suffix(".json.tmp")
    # 600 before any content exists: write-then-chmod would publish a live
    # session cookie to every local user for the duration of the write.
    temp.touch(mode=0o600)
    temp.write_text(json.dumps({SESSION_COOKIE: value}), encoding="utf-8")
    temp.replace(SESSION_FILE)


def clear_session_cookie() -> None:
    """Drop the cached cookie so the next call logs in afresh."""
    SESSION_FILE.unlink(missing_ok=True)


def prompt_credentials() -> tuple[str, str]:
    """Ask for credentials interactively, preferring the hand-written file.

    Returns:
        A ``(username, password)`` pair.
    """
    stored = read_credentials()
    if stored is not None:
        return stored
    username = input("Panel e-mail: ").strip()
    return username, getpass.getpass("Panel password: ")


def attach_cached_session(session: requests.Session) -> bool:
    """Attach the cached cookie to ``session``.

    Args:
        session: The session to prime.

    Returns:
        True when a cached cookie was attached.
    """
    cookie = load_session_cookie()
    if cookie is None:
        return False
    session.cookies.set(SESSION_COOKIE, cookie, domain="panel.kuchniavikinga.pl")
    return True


def remember_session(session: requests.Session) -> None:
    """Cache ``session``'s cookie if it carries one."""
    value = session.cookies.get(SESSION_COOKIE)
    if value is not None:
        save_session_cookie(value)
