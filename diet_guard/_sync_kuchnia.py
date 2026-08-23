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

from datetime import datetime, timezone
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

    Prefers the synced cache, and falls back to the hand-written
    ``kuchnia_credentials`` when there is no cache yet.  That fallback is what
    bootstraps the whole feature: the PC is where the password is typed, so
    without it the PC would never publish and the phone would never receive.

    The hand-written file's mtime is its edit time.  It is a coarse clock, but
    it is the only one that file has, and it only has to beat the epoch that an
    unset peer contributes.
    """
    synced = read_synced_credential()
    if synced is not None:
        username, password, edited_at = synced
        return credential_to_log(username, password, edited_at)

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
    edited = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
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
        except (TypeError, KeyError, ValueError, json.JSONDecodeError):
            _logger.warning(
                "Unparsable catering credential pushed by device %r, skipping",
                device_id,
            )

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
