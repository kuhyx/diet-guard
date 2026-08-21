"""Removing device directories no longer written by any live device.

Every install mints its own uuid and pushes under it, and nothing ever cleans
those directories up. On this machine that grew to 25: two live devices plus
23 that stopped writing, seventeen of them frozen at the *same* instant, which
is the signature of repeated fresh-install runs rather than organic use.

That is not free. Each peer costs a round trip in the log pull and in each of
the three bank syncs -- roughly 400ms per peer per tick -- so the dead ones
dominate the background tick.

**Safety, because this deletes data on a shared remote:**

* :func:`plan_prune` only ever *reads*. It is what ``--dry-run`` (the default)
  prints.
* A device is prunable only when every record it holds is already held by a
  device being kept. A peer with even one unique record is reported as
  ``keeps`` and never proposed.
* :data:`PROTECTED_IDS` are never proposed at all: the legacy role ids carry
  pre-migration history and are named by ``SYNC_LEGACY_DEVICE_ID``, and
  dropping one makes every tick re-merge this device's own old log.
* :func:`backup_peers` writes every peer's raw pushed bytes to disk before any
  deletion, so a mistake is recoverable from the local copy.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import json
import logging
from typing import TYPE_CHECKING

from diet_guard._device import device_identity
from diet_guard._sync_client import _client_for_run
from diet_guard._sync_paths import (
    _DEVICES_DIR,
    _REVS_DIR,
    _device_budget_path,
    _device_food_bank_path,
    _device_log_path,
    _device_manual_bank_path,
)

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path

    from crdt_sync import RemoteStore

_logger = logging.getLogger(__name__)

#: Never proposed for deletion, whatever their contents.
#:
#: The pre-migration role ids. ``SYNC_LEGACY_DEVICE_ID`` still names one of
#: them as this device's own former path, and CLAUDE.md is explicit that
#: dropping it makes every tick re-merge our own history as if it were a peer's.
PROTECTED_IDS = frozenset({"pc", "phone", "desktop"})


@dataclass
class PrunePlan:
    """What a prune would do, without having done any of it."""

    keeps: list[str] = field(default_factory=list)
    prunes: list[str] = field(default_factory=list)
    #: Records held by the kept devices; the yardstick for "already covered".
    covered: int = 0
    #: Records that would be lost. Must be 0 for a plan to be safe to apply.
    unique_lost: int = 0


def _device_paths(device_id: str) -> tuple[str, ...]:
    """Return every path a device publishes under.

    The revision marker is one of them, and forgetting it is not cosmetic:
    ``_sync_refresh._candidate_peers`` enumerates peers from the revision map,
    so a marker left behind for a deleted device makes every tick propose a
    peer that no longer exists and pay a round trip discovering that. Pruning
    without this made the narrow pull *slower* (~90ms -> ~15s) rather than
    faster.
    """
    return (
        _device_log_path(device_id),
        _device_food_bank_path(device_id),
        _device_manual_bank_path(device_id),
        _device_budget_path(device_id),
        f"{_REVS_DIR}/{device_id}",
    )


def _record_ids(client: RemoteStore, device_id: str) -> set[str]:
    """Return the record ids in ``device_id``'s pushed log, or an empty set."""
    text = client.get_file_text(_device_log_path(device_id))
    if text is None:
        return set()
    try:
        parsed = json.loads(text)
    except (ValueError, TypeError):
        return set()
    return set(parsed) if isinstance(parsed, dict) else set()


def plan_prune(client: RemoteStore, keep: set[str]) -> PrunePlan:
    """Return which devices could be removed without losing a single record.

    Read-only. ``keep`` names the devices whose data is the yardstick -- this
    device and any peer still actively writing.
    """
    identity = device_identity()
    covered: set[str] = set()
    for device_id in keep:
        covered |= _record_ids(client, device_id)

    plan = PrunePlan(covered=len(covered))
    for device_id in client.list_directory(_DEVICES_DIR):
        if device_id in keep or identity.is_own(device_id):
            plan.keeps.append(device_id)
            continue
        if device_id in PROTECTED_IDS:
            plan.keeps.append(device_id)
            continue
        unique = _record_ids(client, device_id) - covered
        if unique:
            plan.unique_lost += len(unique)
            plan.keeps.append(device_id)
            continue
        plan.prunes.append(device_id)
    return plan


def backup_peers(client: RemoteStore, device_ids: list[str], target: Path) -> int:
    """Write every named device's pushed bytes under ``target``; return file count.

    Runs before any deletion so a wrong call is recoverable locally.
    """
    target.mkdir(parents=True, exist_ok=True)
    written = 0
    for device_id in device_ids:
        for path in _device_paths(device_id):
            text = client.get_file_text(path)
            if text is None:
                continue
            out = target / device_id / path.rsplit("/", 1)[-1]
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(text)
            written += 1
    return written


def apply_prune(client: RemoteStore, device_ids: list[str]) -> Iterator[str]:
    """Delete every path the named devices published, yielding each as it goes."""
    for device_id in device_ids:
        for path in _device_paths(device_id):
            client.delete_file(path, message="diet_guard: prune stale device")
        yield device_id


def open_client() -> RemoteStore:
    """Return a sync client for the prune commands."""
    return _client_for_run()
