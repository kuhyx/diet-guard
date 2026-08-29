"""Credentials and the cached session cookie for the catering import.

Sole reader of :data:`~diet_guard._constants.KUCHNIA_CREDENTIALS_FILE` and
:data:`~diet_guard._constants.KUCHNIA_SESSION_FILE`, so the test-suite redirect
in ``conftest._isolate_state`` has exactly one place to patch.

Both files live under ``~/.config/diet_guard/`` at mode 600, outside
``DATA_DIR``.  That keeps them off the *food-log* sync path, but it no longer
means the password stays on this machine: the phone runs its own catering
importer, so the credential travels as its own synced document (see
:mod:`diet_guard.sync_merge._kuchnia`), in plaintext, by the user's explicit
choice.  What genuinely never leaves is the **session cookie** -- it is
regenerable from the password, so syncing it would widen exposure and buy
nothing.

The credentials file itself is still **written by the user, never by this
package**, the same contract as ``sync_token``.  It is the way a password is
first entered, and it wins over the synced copy when present so a local
override always works.  The synced copy is written by
:mod:`diet_guard._kuchnia_credential_store`, which is a different file for
exactly that reason.
"""

from __future__ import annotations

import json
import logging

from diet_guard._constants import (
    KUCHNIA_CREDENTIALS_FILE,
    KUCHNIA_LAST_IMPORT_FILE,
    KUCHNIA_SESSION_FILE,
)
from diet_guard._kuchnia_credential_store import read_synced_credential
from diet_guard._kuchnia_errors import KuchniaError

_logger = logging.getLogger(__name__)

#: The only cookie the panel issues on login. It sets no ``XSRF-TOKEN``, so the
#: CSRF echo its own JavaScript performs is a no-op for this account -- the
#: session cookie alone authenticates.
SESSION_COOKIE = "SESSION"

_EXPECTED_LINES = 2

_SETUP_HINT = (
    "create it with:\n"
    "  install -m 600 /dev/null {path}\n"
    "  printf '%s\\n%s\\n' 'you@example.com' 'your-password' > {path}"
)


def read_credentials() -> tuple[str, str]:
    """Return the panel ``(username, password)``.

    Two sources, in this order:

    1. ``kuchnia_credentials``, hand-written by the user. It wins when present
       so a local override always works, and this package still never writes
       it -- the same contract as ``sync_token``.
    2. Whatever the cross-device merge resolved
       (:mod:`diet_guard._kuchnia_credential_store`). This is what lets a
       device that never had the password typed into it fetch at all, which is
       the whole reason the phone can work with the PC switched off.

    Returns:
        The credentials.

    Raises:
        KuchniaError: When neither source has a usable credential. The message
            carries the setup command, mirroring ``_read_token``.
    """
    path = KUCHNIA_CREDENTIALS_FILE
    if not path.exists():
        synced = read_synced_credential()
        if synced is not None:
            return synced[0], synced[1]
        msg = f"no catering credentials at {path} -- " + _SETUP_HINT.format(path=path)
        raise KuchniaError(msg)
    lines = [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if len(lines) < _EXPECTED_LINES:
        msg = f"{path} needs two lines (e-mail, then password); found {len(lines)}"
        raise KuchniaError(msg)
    return lines[0], lines[1]


def load_session_cookie() -> str | None:
    """Return the cached session cookie, or None when there is no usable cache.

    Never raises: a missing, unreadable or corrupt cache simply means "log in
    again", which is always a valid next step.
    """
    if not KUCHNIA_SESSION_FILE.exists():
        return None
    try:
        cached = json.loads(KUCHNIA_SESSION_FILE.read_text(encoding="utf-8"))
    except OSError, json.JSONDecodeError:
        _logger.warning("Catering session cache %s is unreadable", KUCHNIA_SESSION_FILE)
        return None
    value = cached.get(SESSION_COOKIE) if isinstance(cached, dict) else None
    return value if isinstance(value, str) and value else None


def save_session_cookie(value: str) -> None:
    """Cache ``value``, created mode 600 before it holds anything.

    ``touch(mode=0o600)`` first, then write, then atomically replace: writing
    and chmod'ing afterwards would leave a live session cookie readable by
    every local user for the duration of the write.
    """
    KUCHNIA_SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    temp = KUCHNIA_SESSION_FILE.with_suffix(".json.tmp")
    temp.touch(mode=0o600)
    temp.write_text(json.dumps({SESSION_COOKIE: value}), encoding="utf-8")
    temp.replace(KUCHNIA_SESSION_FILE)


def clear_session_cookie() -> None:
    """Drop the cached cookie so the next refresh logs in afresh."""
    KUCHNIA_SESSION_FILE.unlink(missing_ok=True)


def last_import_day() -> str:
    """Return the ISO date whose delivery was last fetched, or "" if none.

    Never raises: an unreadable marker just means "fetch again", which is
    always safe.
    """
    if not KUCHNIA_LAST_IMPORT_FILE.exists():
        return ""
    try:
        return KUCHNIA_LAST_IMPORT_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def record_import_day(day: str) -> None:
    """Remember that ``day``'s delivery has been fetched.

    Best-effort: this is a rate limit, not state anyone depends on. A failure
    to write it costs one extra fetch, which is strictly better than failing an
    import that already succeeded.
    """
    try:
        KUCHNIA_LAST_IMPORT_FILE.parent.mkdir(parents=True, exist_ok=True)
        KUCHNIA_LAST_IMPORT_FILE.write_text(day, encoding="utf-8")
    except OSError:
        _logger.warning("Could not record the catering import day")
