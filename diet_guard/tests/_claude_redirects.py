"""The redirects for the "send to Claude" relay and estimator.

Split out of ``_state_redirects.py`` for the 250-line cap. Two kinds, both
**fail closed**:

* the network and subscription entry points (RTDB connect, the model call)
  are replaced by a function that *raises*, so a test that reaches one fails
  loudly instead of talking to the live database or spending kuhy's Claude
  quota; a test that needs one patches in its own fake;
* the sync touch points return ``None`` like the other call sites, and the
  on-disk paths (sandbox dir, kuhy's real Claude login) point into ``tmp_path``.
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import patch

if TYPE_CHECKING:
    from collections.abc import Callable
    from pathlib import Path
    from unittest.mock import _patch


class RealIoBlockedError(AssertionError):
    """A test reached a real network or model entry point."""


def blocked(name: str) -> Callable[..., object]:
    """A replacement for ``name`` that raises when called."""

    def refuse(*_args: object, **_kwargs: object) -> object:
        msg = f"{name} reached from a test: patch your own fake in"
        raise RealIoBlockedError(msg)

    return refuse


def claude_redirects(tmp_path: Path) -> list[_patch[object]]:
    """Every patch that keeps the relay worker and estimator off live state."""
    return [
        patch(
            "diet_guard._claude_connect.connect_sealed",
            blocked("_claude_connect.connect_sealed"),
        ),
        patch("diet_guard._claude_sdk.run_model", blocked("_claude_sdk.run_model")),
        # The gate's Claude button resolves the estimator lazily through this
        # name; blocked here so no gate test can reach the model or the quota.
        patch(
            "diet_guard._gatelock_claude.estimate_meal",
            blocked("_gatelock_claude.estimate_meal"),
        ),
        patch("diet_guard._claude_sync.pull_peers", return_value=None),
        patch("diet_guard._claude_sync.publish", return_value=None),
        patch("diet_guard._claude_sandbox.SANDBOX_DIR", tmp_path / "claude-sandbox"),
        patch(
            "diet_guard._claude_sandbox.HOST_LOGIN_FILE",
            tmp_path / "host-claude-credentials.json",
        ),
    ]
