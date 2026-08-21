"""CLI handler for the ``prune-peers`` subcommand.

Removes device directories no longer written by any live device. Dry-run by
default -- see :mod:`diet_guard._prune_peers` for why every safety rail is
there.
"""

from __future__ import annotations

from importlib import import_module
from pathlib import Path
import sys
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import argparse
    from collections.abc import Callable

# ``_prune_peers`` reaches ``crdt_sync`` -> ``requests``; registering this
# subparser must not drag an HTTP stack into every other command.
_LAZY_ATTRS = ("plan_prune", "backup_peers", "apply_prune", "open_client")


def __getattr__(name: str) -> object:
    """Resolve the deferred prune helpers on first attribute access."""
    if name not in _LAZY_ATTRS:
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    return getattr(import_module("diet_guard._prune_peers"), name)


def register_prune_subparser(sub: argparse._SubParsersAction) -> None:
    """Register the ``prune-peers`` subcommand on ``sub``."""
    prune = sub.add_parser(
        "prune-peers",
        help="Remove sync device directories nothing writes to any more.",
    )
    prune.add_argument(
        "--keep",
        action="append",
        default=[],
        metavar="DEVICE_ID",
        help="A peer to treat as live (repeatable). This device is implicit.",
    )
    prune.add_argument(
        "--backup-dir",
        default=None,
        help="Where to back up peer data before deleting (needed with --apply).",
    )
    prune.add_argument(
        "--apply",
        action="store_true",
        help="Actually delete. Without this the command only reports.",
    )


def cmd_prune_peers(
    emit: Callable[[str], None],
    *,
    keep: list[str],
    backup_dir: str | None,
    apply: bool,
) -> int:
    """Report -- and with ``--apply``, remove -- devices nothing writes to.

    Returns:
        0 on success, 1 when the plan is unsafe or a backup path is missing.
    """
    module = sys.modules[__name__]
    client = module.open_client()
    plan = module.plan_prune(client, set(keep))

    emit(f"{len(plan.keeps)} device(s) kept, {len(plan.prunes)} prunable.")
    emit(f"records held by kept devices: {plan.covered}")
    for device_id in plan.prunes:
        emit(f"  prunable: {device_id}")
    if plan.unique_lost:
        emit(
            f"refusing to prune: {plan.unique_lost} record(s) exist only on "
            "peers that would be removed.",
        )
        return 1
    if not plan.prunes:
        emit("nothing to prune.")
        return 0
    if not apply:
        emit("dry run -- pass --apply (with --backup-dir) to delete.")
        return 0
    if backup_dir is None:
        emit("--apply requires --backup-dir; refusing to delete without a backup.")
        return 1

    written = module.backup_peers(client, plan.prunes, Path(backup_dir))
    emit(f"backed up {written} file(s) to {backup_dir}")
    for device_id in module.apply_prune(client, plan.prunes):
        emit(f"  pruned: {device_id}")
    emit(f"pruned {len(plan.prunes)} device(s).")
    return 0
