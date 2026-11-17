"""Fakes for the relay and estimator tests: a fake SDK, a fake RTDB, fresh modules.

The conftest redirects replace the relay's entry points (``connect_sealed``,
``run_model``, the sync touch points) with blockers. A test of the *real*
function loads a pristine copy of its module with :func:`fresh` instead of
fighting the patch.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import sys
from types import ModuleType, SimpleNamespace
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import AsyncIterator
    from pathlib import Path


def fresh(module: ModuleType) -> ModuleType:
    """A pristine second copy of ``module``, untouched by any redirect."""
    name = f"{module.__name__}__fresh"
    spec = importlib.util.spec_from_file_location(name, module.__file__)
    assert spec is not None
    assert spec.loader is not None
    copy = importlib.util.module_from_spec(spec)
    sys.modules[name] = copy
    spec.loader.exec_module(copy)
    return copy


class FakeResult:
    """A stand-in ``ResultMessage``."""

    def __init__(self, structured: object, *, is_error: bool = False) -> None:
        """Carry the structured answer and the error flag."""
        self.structured_output = structured
        self.is_error = is_error
        self.subtype = "error_during_execution" if is_error else "success"
        self.errors = ["boom"] if is_error else None
        self.result = "text"


class FakeSdk(SimpleNamespace):
    """A stand-in ``claude_agent_sdk`` that records what it was asked."""

    def __init__(self, messages: list[object], *, hang: bool = False) -> None:
        """Replay ``messages``; with ``hang`` the query never finishes."""
        self.calls: list[dict[str, Any]] = []
        self._messages = messages
        self._hang = hang
        super().__init__(
            ClaudeAgentOptions=SimpleNamespace,
            ResultMessage=FakeResult,
            query=self._query,
        )

    async def _query(
        self, *, prompt: AsyncIterator[dict[str, Any]], options: object
    ) -> AsyncIterator[object]:
        sent = [item async for item in prompt]
        self.calls.append({"sent": sent, "options": options})
        if self._hang:
            await asyncio.sleep(60)
        for message in self._messages:
            yield message


def write_host_login(path: Path, expires_ms: int) -> None:
    """kuhy's CLI login as it looks on disk, refresh token included."""
    path.write_text(
        json.dumps(
            {
                "claudeAiOauth": {
                    "accessToken": "tok",
                    "refreshToken": "SECRET-REFRESH",
                    "expiresAt": expires_ms,
                },
                "mcpOAuth": {"server": {"token": "SECRET-MCP"}},
            }
        ),
        encoding="utf-8",
    )
