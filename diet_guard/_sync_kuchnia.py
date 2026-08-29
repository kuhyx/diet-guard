"""Pull/merge/push for the catering panel credential.

Its own module rather than a fourth function in :mod:`diet_guard._sync_banks`,
which is already at the repo's 250-line ceiling.

Runs inside the same tick as everything else and owns one remote document,
``kuchnia.json``.  Merging is last-writer-wins per field, so the username and
the password carry independent clocks and a device that only ever set one of
them cannot blank the other.

**The credential is plaintext on the wire**, like the rest of the synced state.
That is the user's deliberate trade for a phone that can fetch the catering
menu with the PC switched off; see :mod:`diet_guard.sync_merge._kuchnia`.
"""

from __future__ import annotations

from datetime import UTC, datetime
import json
import logging
from typing import TYPE_CHECKING

from crdt_sync import merge_logs

from diet_guard import _kuchnia_config
from diet_guard._device import device_identity
from diet_guard._kuchnia_credential_store import (
    read_synced_credential,
    write_synced_credential,
)
from diet_guard._kuchnia_errors import KuchniaError
from diet_guard._sync_paths import _device_kuchnia_path
from diet_guard.sync_merge import (
    credential_to_log,
    log_to_credential,
    parse_remote_credential,
)

if TYPE_CHECKING:  # pragma: no cover - typing only
    from collections.abc import Sequence

    from crdt_sync import GitHubSyncClient, Log

_logger = logging.getLogger(__name__)


def _local_credential_log() -> Log:
    """Return this device's contribution to the credential merge.

    Sourced from the synced cache, which carries a real edit time.  Returns an
    empty ``Log`` when there is no cache, so a device that has never merged
    contributes nothing rather than competing on a made-up clock.

    The hand-written ``kuchnia_credentials`` deliberately does **not** feed
    this; see :func:`_bootstrap_credential_log`.
    """
    synced = read_synced_credential()
    if synced is None:
        return {}
    username, password, edited_at = synced
    return credential_to_log(username, password, edited_at)


def _bootstrap_credential_log() -> Log:
    """Return the hand-written credential, for use only when no peer has one.

    The PC is where the password is first typed, so without a bootstrap no
    device would ever publish and the phone would never receive one.  But this
    file has no edit time of its own -- only an mtime, which ``git checkout``,
    a backup restore, or re-running the ``install -m 600`` setup line all bump
    forward without the credential changing.

    So it is a fallback of *last resort*, applied only when the merge came back
    empty, rather than a competitor in the LWW race.  Letting it compete on
    mtime meant a PC whose file had merely been touched could overwrite a
    password the user had just typed on the phone -- reproduced before this
    split existed, and now pinned by
    ``test_a_touched_handwritten_file_cannot_clobber_a_peer``.

    Its stamp is the mtime all the same: something has to go on the wire, and
    once this has been published the synced cache takes over permanently.
    """
    # Reached through the module rather than imported by value:
    # `conftest._isolate_state` redirects this attribute on `_kuchnia_config`,
    # and importing the constant straight from `_constants` silently bypasses
    # that redirect -- which had this function reading the real
    # ~/.config credentials during the test suite.
    path = _kuchnia_config.KUCHNIA_CREDENTIALS_FILE
    if not path.exists():
        return {}
    try:
        username, password = _kuchnia_config.read_credentials()
    except KuchniaError:
        return {}
    edited = datetime.fromtimestamp(path.stat().st_mtime, tz=UTC)
    return credential_to_log(
        username, password, edited.astimezone().isoformat(timespec="seconds")
    )


def _sync_kuchnia_credential(
    client: GitHubSyncClient, device_ids: Sequence[str]
) -> None:
    """Pull peers' catering credentials, merge, cache locally, push.

    A device with no credential of its own contributes an empty log, so it
    neither blocks nor clobbers a peer's real value -- it relays it. When no
    device has ever set one, nothing is written or pushed.

    Args:
        client: The already-authenticated sync client for this tick.
        device_ids: Every device id seen in the remote tree.
    """
    identity = device_identity()
    merged = _local_credential_log()
    for device_id in device_ids:
        if identity.is_own(device_id):
            continue
        text = client.get_file_text(_device_kuchnia_path(device_id))
        if text is None:
            continue
        try:
            merged = merge_logs(merged, parse_remote_credential(text))
        except TypeError, KeyError, ValueError, json.JSONDecodeError:
            _logger.warning(
                "Unparsable catering credential pushed by device %r, skipping",
                device_id,
            )

    if not merged:
        # Nobody -- not this device's cache, not any peer -- has a credential
        # yet. Only now does the hand-written file get to speak, so its
        # untrustworthy mtime can never outrank a real edit from a peer.
        merged = _bootstrap_credential_log()

    resolved = log_to_credential(merged)
    if resolved is None:
        return
    username, password, edited_at = resolved
    # Only write when something actually changed. `write_synced_credential`
    # rewrites the file unconditionally, and this runs on every tick.
    if read_synced_credential() != (username, password, edited_at):
        write_synced_credential(username, password, edited_at)

    push_json = json.dumps(
        {record_id: record.to_dict() for record_id, record in merged.items()},
        indent=2,
    )
    client.put_file_text(
        _device_kuchnia_path(identity.device_id),
        push_json,
        message="diet_guard sync",
    )
