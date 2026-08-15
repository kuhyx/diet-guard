"""Choosing and building the remote store one sync tick will use.

Split out of ``_sync.py`` for file size.

Two backends, and the tick needs exactly one: Firebase (primary, configured
at ``~/.config/crdt-sync/``) or a GitHub PAT mirror at
``~/.config/diet_guard/sync_token``. Neither configured is not an error --
:func:`_client_for_run` raises :class:`~diet_guard._sync.SyncError` and the
caller logs ``sync not configured`` and no-ops, which is what a machine that
has never been set up should do on a 15-minute timer.

``ConfigError`` subclasses ``Exception`` directly rather than
``RemoteSyncError``, so it is caught explicitly here and translated -- a
sibling-not-subclass relationship that has bitten this file before.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from crdt_sync import (
    CONFIG_FILE,
    ConfigError,
    FirebaseAuthError,
    GitHubSyncClient,
    RemoteSyncError,
    firebase_client_for,
    mirror_client_for,
)

from diet_guard._constants import (
    SYNC_REPO_NAME,
    SYNC_REPO_OWNER,
    SYNC_TIMEOUT_SECONDS,
    SYNC_TOKEN_FILE,
)
from diet_guard._sync_errors import SyncError

if TYPE_CHECKING:
    from crdt_sync import RemoteStore

_logger = logging.getLogger(__name__)


def _remote_client(github: GitHubSyncClient) -> RemoteStore:
    """Return the backend to sync against.

    Firebase when ``~/.config/crdt-sync/`` is set up, with GitHub kept as a
    mirror so a device that has not moved yet still converges; GitHub alone
    otherwise. An unconfigured machine keeps syncing exactly as before.

    Every sub-sync here (log, budget, food bank, manual bank) takes the client
    as a parameter, so this one swap covers all of them.

    The config file is checked before constructing anything, so an
    unconfigured machine never reaches the network -- otherwise a suite that
    blocks real sockets fails here rather than in the code under test.

    Rolling back is deleting this function and passing ``github`` straight
    through: no data moves either way.
    """
    if not CONFIG_FILE.is_file():
        return github
    try:
        return mirror_client_for("diet_guard", github)
    except (ConfigError, FirebaseAuthError, RemoteSyncError) as exc:
        _logger.warning("Firebase unavailable, syncing via GitHub only: %s", exc)
        return github


def _client_for_run() -> RemoteStore:
    """Return the backend for one sync run, requiring only *one* to be set up.

    The PAT is no longer mandatory. Firebase is the primary backend now, and
    requiring a GitHub token before ever constructing it meant a
    Firebase-configured machine with no PAT could not sync at all -- the
    commits that fixed exactly this ("Auto-sync on a Firebase-only device")
    changed only the Dart side, leaving the Python half behind.

    A missing PAT is therefore fatal only when Firebase is *also* unconfigured,
    which is the genuine "nothing is set up" case the caller must report.
    """
    try:
        token = _read_token()
    except SyncError:
        if not CONFIG_FILE.is_file():
            raise
        # Firebase-only: there is no GitHub client to mirror to, so use the
        # primary directly rather than failing the whole run.
        #
        # ConfigError is translated rather than propagated: it is *not* a
        # RemoteSyncError (it subclasses Exception directly), so letting it out
        # would escape every caller's catch tuple and raise a traceback out of
        # the gate's fail-closed "Fetch from sync" button -- the exact failure
        # the RemoteSyncError swap was made to stop. A config file that exists
        # but is unusable is reached by precisely this branch.
        try:
            return firebase_client_for("diet_guard")
        except ConfigError as exc:
            message = f"Firebase config at {CONFIG_FILE} is unusable: {exc}"
            raise SyncError(message) from exc
    return _remote_client(
        GitHubSyncClient(
            SYNC_REPO_OWNER,
            SYNC_REPO_NAME,
            token,
            timeout_seconds=SYNC_TIMEOUT_SECONDS,
        )
    )


def _read_token() -> str:
    """Return the saved sync PAT, stripped of trailing whitespace.

    Raises:
        SyncError: If the token file is missing or empty -- the user has not
            completed the one-time github.com setup step yet.
    """
    if not SYNC_TOKEN_FILE.exists():
        message = (
            f"no sync token at {SYNC_TOKEN_FILE} -- create a fine-grained "
            "GitHub PAT scoped to the syncs repo's contents and "
            f"save it there (mode 600), then re-run sync"
        )
        raise SyncError(message)
    token = SYNC_TOKEN_FILE.read_text().strip()
    if not token:
        msg = f"{SYNC_TOKEN_FILE} is empty"
        raise SyncError(msg)
    return token
