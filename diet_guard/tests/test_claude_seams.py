"""Canaries: the relay/estimator seams must fail closed, not open.

A redirect that names a moved or renamed target redirects nothing and the
suite stays green while it reaches the live database or kuhy's Claude quota
(``fail-open-test-seams``). Each test here is red the moment its patch is
missing from ``_claude_redirects.claude_redirects``: the entry point must
*raise* the blocker, the sync touch points must be mocks, and the on-disk
paths must live under ``tmp_path``.
"""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING
from unittest.mock import Mock

import pytest

from diet_guard import _claude_connect, _claude_sandbox, _claude_sdk, _claude_sync
from diet_guard.tests._claude_redirects import RealIoBlockedError

if TYPE_CHECKING:
    from pathlib import Path


def test_rtdb_connect_is_blocked() -> None:
    """The worker's RTDB connect raises instead of dialling Firebase."""
    with pytest.raises(RealIoBlockedError):
        asyncio.run(_claude_connect.connect_sealed())


def test_model_call_is_blocked() -> None:
    """The model call raises instead of spending kuhy's subscription."""
    with pytest.raises(RealIoBlockedError):
        asyncio.run(_claude_sdk.run_model("s", [], {}, budget_s=1))


@pytest.mark.parametrize("name", ["pull_peers", "publish"])
def test_sync_touch_points_are_patched(name: str) -> None:
    """Neither the narrow pull nor the full tick can reach the remote."""
    touch = getattr(_claude_sync, name)
    assert isinstance(touch, Mock)
    assert touch() is None


def test_sandbox_and_host_login_are_under_tmp(tmp_path: Path) -> None:
    """The sandbox dir and kuhy's real login file never name the real home."""
    assert _claude_sandbox.SANDBOX_DIR.is_relative_to(tmp_path)
    assert _claude_sandbox.HOST_LOGIN_FILE.is_relative_to(tmp_path)
