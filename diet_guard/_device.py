"""This machine's persisted sync identity.

Its own module rather than living in :mod:`diet_guard._sync`, because
:mod:`diet_guard.sync_merge` needs it too for HLC stamping and importing
``_sync`` from there would be a cycle.
"""

from __future__ import annotations

from crdt_sync import DeviceIdentity, load_device_identity

from diet_guard._constants import SYNC_DEVICE_ID_FILE, SYNC_LEGACY_DEVICE_ID


def device_identity() -> DeviceIdentity:
    """Return this machine's sync identity, minting it on first use.

    Deliberately not cached at import time: the id file is redirected
    per-test, and a module-level constant would freeze whichever value the
    first import happened to see. Reading a small file once per sync tick is
    cheaper than that surprise.
    """
    return load_device_identity(SYNC_DEVICE_ID_FILE, legacy_id=SYNC_LEGACY_DEVICE_ID)


def device_id() -> str:
    """Return just this machine's current sync id, for HLC stamping."""
    return device_identity().device_id
