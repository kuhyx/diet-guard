"""Repo-relative paths every device pushes its state to.

Split out of ``_sync.py`` for file size. These are the wire layout of the
`kuhyx/syncs` repo, so they are shared by the tick that pushes the food log
(:mod:`diet_guard._sync`) and the one that pushes the banks and budget
(:mod:`diet_guard._sync_banks`) -- a second copy of the layout in either
module is how one of them starts writing where the other does not look.

Every device pushes under its own persisted per-install uuid, never a role
constant; see :mod:`diet_guard._device`.
"""

from __future__ import annotations

_DEVICES_DIR = "diet-guard-sync/devices"

#: Where per-device revision markers live, used to skip re-reading an
#: unchanged remote log.
_REVS_DIR = "diet-guard-sync/revs"


def _device_log_path(device_id: str) -> str:
    """Return the repo-relative path a device's full log is pushed to."""
    return f"{_DEVICES_DIR}/{device_id}/food_log.json"


def _device_food_bank_path(device_id: str) -> str:
    """Return one device's pushed derived-food-bank path."""
    return f"{_DEVICES_DIR}/{device_id}/food_bank.json"


def _device_manual_bank_path(device_id: str) -> str:
    """Return one device's pushed curated-food-bank path."""
    return f"{_DEVICES_DIR}/{device_id}/food_bank_manual.json"


def _device_budget_path(device_id: str) -> str:
    """Return the repo-relative path a device's budget is pushed to."""
    return f"{_DEVICES_DIR}/{device_id}/budget.json"


def _device_kuchnia_path(device_id: str) -> str:
    """Return one device's pushed catering-credential path.

    Its own document rather than a field on ``budget.json``: the budget is
    written back at default permissions, and a password riding inside it would
    be readable by anything that reads the budget.
    """
    return f"{_DEVICES_DIR}/{device_id}/kuchnia.json"
