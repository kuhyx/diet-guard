"""Shared fixtures for diet_guard tests.

Two safety nets run for every test:

* ``_isolate_state`` redirects the food log, sealed budget, and gate lock into
  ``tmp_path`` so a test can never read or clobber the real ``~/.local/share``.
* ``_block_real_tk`` swaps ``tk`` and the ``_GateRoot`` window class inside
  ``_gatelock`` for mocks, so no test can open a real fullscreen window or grab
  the keyboard even if it forgets to.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path


@pytest.fixture(autouse=True)
def _isolate_state(tmp_path: Path) -> Iterator[None]:
    """Redirect all on-disk diet_guard state into a temp dir."""
    with (
        patch(
            "python_pkg.diet_guard._budget.BUDGET_FILE",
            tmp_path / ".budget",
        ),
        patch(
            "python_pkg.diet_guard._state.FOOD_LOG_FILE",
            tmp_path / "food_log.json",
        ),
        patch(
            "python_pkg.diet_guard._foodbank.FOOD_BANK_FILE",
            tmp_path / "food_bank.json",
        ),
        patch(
            "python_pkg.diet_guard._gatelock.GATE_LOCK_FILE",
            tmp_path / ".gate.lock",
        ),
    ):
        yield


@pytest.fixture(autouse=True)
def _block_real_tk() -> Iterator[None]:
    """Replace tk + the window class in _gatelock so no real window can open."""
    with (
        patch("python_pkg.diet_guard._gatelock.tk", MagicMock()),
        patch("python_pkg.diet_guard._gatelock._GateRoot", MagicMock()),
    ):
        yield


@pytest.fixture(autouse=True)
def _hmac_key(tmp_path: Path) -> Iterator[None]:
    """Point the shared HMAC key at a deterministic temp file.

    Makes signing/verification work the same in any environment (including CI,
    which has no ``/etc/workout-locker/hmac.key``).  Tests that need the
    no-key path patch ``compute_entry_hmac`` to return None locally.
    """
    key = tmp_path / "hmac.key"
    key.write_bytes(b"diet-guard-test-key-0123456789ab")
    with patch("python_pkg.shared.log_integrity.HMAC_KEY_FILE", key):
        yield
