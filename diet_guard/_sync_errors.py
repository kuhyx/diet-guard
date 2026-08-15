"""The one exception a sync tick raises before it can start.

Its own module so that :mod:`diet_guard._sync_client`, which raises it, and
:mod:`diet_guard._sync`, which catches it and re-exports it for callers, do
not have to import each other.

Deliberately *not* a subclass of ``crdt_sync.RemoteSyncError``: this means
"never got far enough to talk to a remote" (no PAT, no usable Firebase
config), which callers treat as a quiet no-op rather than as a sync failure
worth surfacing.
"""

from __future__ import annotations


class SyncError(Exception):
    """Raised when a sync run cannot even start (no usable PAT)."""
