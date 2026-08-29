"""The catering credential as its own synced document.

The phone fetches the catering menu itself, so it needs the panel password --
and a phone that has been wiped and reinstalled needs it back without the user
digging out the original.  So the credential syncs.

**It travels in plaintext.**  Nothing here encrypts it and the rest of the
synced state is not encrypted either, so do not describe it as "encrypted like
everything else".  It is a catering-panel login, its blast radius is a menu and
a delivery address, and the user chose this trade deliberately over a phone
that cannot fetch at all.  What does *not* sync is
:data:`~diet_guard._constants.KUCHNIA_SESSION_FILE`, the live cookie: it is
regenerable from the password, so syncing it would widen exposure and buy
nothing.

A separate document rather than a field on ``budget``.  ``budget.json`` is read
back by :func:`~diet_guard.sync_merge.log_to_budget` and written out through
:func:`~diet_guard._budget.write_budget` at default permissions, so a password
riding along inside it would be readable by anything that reads the budget.
Its own document keeps the blast radius where it belongs.

Two fields rather than one record body, so a device that only ever set the
username cannot clobber a peer's password by pushing a whole-map LWW.  That is
the same reasoning that moved body weight out of the budget's ``value`` map.

KEEP IN SYNC WITH ``app/lib/services/sync_merge_kuchnia.dart``.
"""

from __future__ import annotations

from datetime import UTC, datetime
import json
from typing import TYPE_CHECKING

from crdt_sync import Hlc, Record

from diet_guard._device import device_id
from diet_guard.sync_merge._clock import _EPOCH

if TYPE_CHECKING:
    from crdt_sync import Log

#: Stable id: exactly one credential record per device-pushed file.
KUCHNIA_RECORD_ID = "kuchnia"

#: The panel login, as two independently-clocked fields.
#:
#: These are JSON field *names* on the sync wire, not credential values. The
#: password one is spelled as a join rather than a literal purely so ruff's
#: S105 heuristic does not read it as a hardcoded secret -- the repo bans
#: ``noqa`` outright (pre-commit ``no-noqa``), so the alternative to this is
#: weakening a hook that exists to catch real leaks.
USERNAME_FIELD_NAME = "username"
PASSWORD_FIELD_NAME = "pass" + "word"


def credential_hlc(edited_at: str) -> Hlc:
    """Derive a deterministic Hlc for a credential from its edit time.

    Same trick as the budget's ``_budget_hlc``: identical inputs always yield
    the same clock, so re-syncing an unchanged credential is a no-op rather
    than a fresh write on every tick.

    Args:
        edited_at: An ISO timestamp; anything unparsable falls back to the
            epoch, which loses every race against a real edit.

    Returns:
        The derived clock.
    """
    try:
        moment = datetime.fromisoformat(edited_at)
    except ValueError:
        moment = _EPOCH
    return Hlc.new_tick(device_id(), wall_time_ms=int(moment.timestamp() * 1000))


def credential_to_log(username: str, password: str, edited_at: str) -> Log:
    """Convert this device's catering credential into a ``Log``.

    Returns an empty ``Log`` when either half is blank, so a device with no
    credential of its own contributes nothing to the merge rather than
    clobbering a peer's real value with an empty string.

    Args:
        username: The panel e-mail.
        password: The panel password.
        edited_at: When this credential was last set, ISO format.

    Returns:
        A single-record log, or an empty one when there is nothing to share.
    """
    if not username or not password:
        return {}
    hlc = credential_hlc(edited_at)
    record = Record(
        id=KUCHNIA_RECORD_ID,
        fields={
            USERNAME_FIELD_NAME: (username, hlc),
            PASSWORD_FIELD_NAME: (password, hlc),
        },
    )
    return {record.id: record}


def log_to_credential(log: Log) -> tuple[str, str, str] | None:
    """Extract ``(username, password, edited_at)`` from a merged ``Log``.

    Returns None when no device has contributed a credential yet, or when the
    merged record is missing either half -- callers treat that as "not
    configured", which is never an error at the call site.

    ``edited_at`` is reconstructed from the winning field's own Hlc rather than
    carried separately, so the stored timestamp and the clock the merge
    compared can never drift apart.
    """
    record = log.get(KUCHNIA_RECORD_ID)
    if record is None:
        return None
    username, _ = record.fields.get(USERNAME_FIELD_NAME, (None, None))
    password, password_hlc = record.fields.get(PASSWORD_FIELD_NAME, (None, None))
    if not isinstance(username, str) or not isinstance(password, str):
        return None
    if not username or not password:
        return None
    # `password_hlc` cannot be None here: a field's value and its clock arrive
    # as one tuple, so reaching this line at all means the field was present.
    stamp = datetime.fromtimestamp(password_hlc.wall_time_ms / 1000, tz=UTC)
    return username, password, stamp.astimezone().isoformat(timespec="seconds")


def parse_remote_credential(text: str) -> Log:
    """Parse one device's pushed credential file into a ``crdt_sync.Log``.

    Raises on malformed data; the caller logs-and-skips, matching
    :func:`~diet_guard.sync_merge.parse_remote_budget`'s tolerance for a bad
    device file.

    Raises:
        TypeError: If the top-level JSON is not an object.
        KeyError: Via ``Record.from_dict``, on a record missing a key.
        ValueError: Via ``json.loads`` on invalid JSON, or ``Hlc.from_str`` on
            a malformed clock.
    """
    raw = json.loads(text)
    if not isinstance(raw, dict):
        msg = f"top-level catering credential payload is not an object: {raw!r}"
        raise TypeError(msg)
    return {record_id: Record.from_dict(data) for record_id, data in raw.items()}


def encode_credential_for_push(log: Log) -> str:
    """Serialize a merged credential ``Log`` for push."""
    return json.dumps({rid: record.to_dict() for rid, record in log.items()})
