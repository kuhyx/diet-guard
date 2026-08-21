"""CLI handler for the ``sync`` subcommand.

Split out from :mod:`diet_guard._cli` to keep that module under the repo's
500-line cap (see ``CLAUDE.md``'s "feat: split oversized modules" history) --
the same reason the gate window logic lives across ``_gatelock*.py`` instead
of one file.
"""

from __future__ import annotations

from importlib import import_module
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import argparse
    from collections.abc import Callable

# ``_cli_args`` imports this module just to register the subparser, but
# ``crdt_sync``/``_sync`` drag in ``requests`` (~78ms). Only the ``sync``
# command itself needs them, so every other subcommand -- notably the gate's
# frequent ``--check`` -- no longer pays for an HTTP stack it will not use.
#
# A module-level ``__getattr__`` (PEP 562) rather than function-local imports
# so ``patch.object(_cli_sync, "run_sync", ...)`` still resolves.
_LAZY_ATTRS = {
    "run_sync": ("diet_guard._sync", "run_sync"),
    "SyncError": ("diet_guard._sync", "SyncError"),
    "RemoteSyncError": ("crdt_sync", "RemoteSyncError"),
}


def __getattr__(name: str) -> object:
    """Resolve a deferred sync import on first attribute access."""
    target = _LAZY_ATTRS.get(name)
    if target is None:
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    module_name, attr = target
    return getattr(import_module(module_name), attr)


def register_sync_subparser(sub: argparse._SubParsersAction) -> None:
    """Register the ``sync`` subcommand on ``sub``."""
    sub.add_parser(
        "sync",
        help="Pull/merge/push the log with other devices via GitHub.",
    )


def cmd_sync(emit: Callable[[str], None]) -> int:
    """Run one sync tick and report what happened via ``emit``.

    Errors are caught here rather than left to propagate: a sync failure
    (missing PAT, network error, repo misconfigured) is routine enough on a
    timer-driven command that the CLI should report it and exit non-zero,
    not crash with a traceback.

    Args:
        emit: A one-line output sink (``_cli._emit``, kept private to that
            module -- passed in rather than imported, so this module has no
            reach-in dependency on ``_cli``'s internals).

    Returns:
        0 on a successful sync, 1 if it could not run or failed partway.
    """
    module = sys.modules[__name__]
    try:
        merged = module.run_sync()
    except module.SyncError as exc:
        emit(f"sync not configured: {exc}")
        return 1
    except module.RemoteSyncError as exc:
        # The shared base, not GitHubSyncError: Firebase's errors are siblings
        # of GitHub's, so catching only the latter let the primary backend's
        # failures crash this timer-driven command with a traceback.
        emit(f"sync failed: {exc}")
        return 1
    total_entries = sum(len(entries) for entries in merged.values())
    emit(f"synced: {total_entries} entries across {len(merged)} day(s).")
    return 0
