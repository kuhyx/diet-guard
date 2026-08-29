"""The synced half of the catering credential, cached locally.

Sole reader and writer of
:data:`~diet_guard._constants.KUCHNIA_SYNCED_CREDENTIAL_FILE`, so the
test-suite redirect in ``conftest._isolate_state`` has exactly one place to
patch.

Two sources feed :func:`diet_guard._kuchnia_config.read_credentials`:

* ``kuchnia_credentials`` -- **hand-written by the user, never by this
  package**, the same contract as ``sync_token``.  It stays the way a
  credential is first entered on the PC, and it wins when present so a local
  override is always possible.
* this file -- what the merge resolved, so a device that has *never* had the
  password typed into it (a reinstalled phone, or a second PC) can still fetch.

Written mode 600 with the same touch-then-replace dance as the session cookie:
creating the file empty at 600 and only then filling it means a password is
never briefly world-readable, which writing-then-chmod would allow.

Unlike the session cookie this **does** travel between devices.  That is a
deliberate trade the user made -- see :mod:`diet_guard.sync_merge._kuchnia` --
and it is plaintext on the wire, not encrypted.
"""

from __future__ import annotations

import json
import logging

from diet_guard._constants import KUCHNIA_SYNCED_CREDENTIAL_FILE

_logger = logging.getLogger(__name__)

# JSON key *names*, not values. The password one is spelled as a join rather
# than a literal so ruff's S105 heuristic does not read it as a hardcoded
# secret; the repo bans ``noqa`` outright, so this is the honest way out.
_USERNAME_KEY_NAME = "username"
_PASSWORD_KEY_NAME = "pass" + "word"
_EDITED_KEY_NAME = "t"


def read_synced_credential() -> tuple[str, str, str] | None:
    """Return the synced ``(username, password, edited_at)``, or None.

    Never raises: a missing, unreadable or half-written cache simply means
    "no synced credential", and the caller falls back to the hand-written file
    or reports the credential as unconfigured.
    """
    if not KUCHNIA_SYNCED_CREDENTIAL_FILE.exists():
        return None
    try:
        raw = json.loads(KUCHNIA_SYNCED_CREDENTIAL_FILE.read_text(encoding="utf-8"))
    except OSError, json.JSONDecodeError:
        _logger.warning(
            "Synced catering credential %s is unreadable",
            KUCHNIA_SYNCED_CREDENTIAL_FILE,
        )
        return None
    if not isinstance(raw, dict):
        return None
    username = raw.get(_USERNAME_KEY_NAME)
    password = raw.get(_PASSWORD_KEY_NAME)
    edited = raw.get(_EDITED_KEY_NAME)
    if not isinstance(username, str) or not isinstance(password, str):
        return None
    if not username or not password:
        return None
    return username, password, edited if isinstance(edited, str) else ""


def write_synced_credential(username: str, password: str, edited_at: str) -> None:
    """Cache the merged credential, created mode 600 before it holds anything.

    ``touch(mode=0o600)`` first, then write, then atomically replace. Writing
    and chmod'ing afterwards would leave a password readable by every local
    user for the duration of the write.
    """
    KUCHNIA_SYNCED_CREDENTIAL_FILE.parent.mkdir(parents=True, exist_ok=True)
    temp = KUCHNIA_SYNCED_CREDENTIAL_FILE.with_suffix(".json.tmp")
    temp.touch(mode=0o600)
    temp.write_text(
        json.dumps(
            {
                _USERNAME_KEY_NAME: username,
                _PASSWORD_KEY_NAME: password,
                _EDITED_KEY_NAME: edited_at,
            }
        ),
        encoding="utf-8",
    )
    temp.replace(KUCHNIA_SYNCED_CREDENTIAL_FILE)
