"""CLI handler for the ``sync`` subcommand.

Split out from :mod:`diet_guard._cli` to keep that module under the repo's
500-line cap (see ``CLAUDE.md``'s "feat: split oversized modules" history) --
the same reason the gate window logic lives across ``_gatelock*.py`` instead
of one file.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from crdt_sync import GitHubSyncError

from diet_guard._sync import SyncError, run_sync

if TYPE_CHECKING:
    import argparse
    from collections.abc import Callable


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
    try:
        merged = run_sync()
    except SyncError as exc:
        emit(f"sync not configured: {exc}")
        return 1
    except GitHubSyncError as exc:
        emit(f"sync failed: {exc}")
        return 1
    total_entries = sum(len(entries) for entries in merged.values())
    emit(f"synced: {total_entries} entries across {len(merged)} day(s).")
    return 0
