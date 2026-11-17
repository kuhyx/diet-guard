"""The one place that talks to Claude: ``claude_agent_sdk`` in the sandbox.

Every other module reaches the model through :func:`run_model`, so a single
test seam (``conftest`` blocks it) keeps the suite off the network and off
kuhy's subscription. The SDK is imported inside the function: the gate and
the CLI import this package at load time, and system Python has no
``claude_agent_sdk`` until the install step ran (the 2026-06-19 outage
shape).

Isolation: ``CLAUDE_CONFIG_DIR`` points at the sandbox (token copy + skill),
``setting_sources`` is empty and there are no tools, MCP servers or hooks, so
nothing of kuhy's own configuration can steer the model.
"""

from __future__ import annotations

import asyncio
from importlib import import_module
from typing import TYPE_CHECKING, Any, Final

from diet_guard import _claude_sandbox

if TYPE_CHECKING:
    from collections.abc import AsyncIterator
    from pathlib import Path

    from claude_agent_sdk import ClaudeAgentOptions

MODEL: Final = "claude-sonnet-5-5"
_SDK: Final = "claude_agent_sdk"  # imported lazily, see the module docstring


class ModelError(RuntimeError):
    """The model call failed or returned no structured answer."""


class ModelTimeoutError(ModelError):
    """The model call ran past its time budget."""


def _blocks(content: list[dict[str, Any]]) -> AsyncIterator[dict[str, Any]]:
    """One streamed user message carrying content blocks (how images go in)."""

    async def stream() -> AsyncIterator[dict[str, Any]]:
        message = {"role": "user", "content": content}
        yield {"type": "user", "message": message, "parent_tool_use_id": None}

    return stream()


def _options(
    system_prompt: str, schema: dict[str, Any], config: Path
) -> ClaudeAgentOptions:
    """Isolated, tool-less options with the structured-output schema."""
    work = config / "work"
    return import_module(_SDK).ClaudeAgentOptions(
        model=MODEL,
        system_prompt=system_prompt,
        tools=[],
        allowed_tools=[],
        setting_sources=[],
        strict_mcp_config=True,
        mcp_servers={},
        cwd=work,
        output_format={"type": "json_schema", "schema": schema},
        effort="low",
        env={
            "CLAUDE_CONFIG_DIR": str(config),
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_AUTOUPDATER": "1",
        },
        extra_args={"disable-slash-commands": None, "no-session-persistence": None},
    )


async def _ask(
    system_prompt: str, content: list[dict[str, Any]], schema: dict[str, Any]
) -> dict[str, Any]:
    config = await asyncio.to_thread(_claude_sandbox.prepare)
    if config is None:
        msg = "no Claude login to copy into the sandbox"
        raise ModelError(msg)
    options = _options(system_prompt, schema, config)
    answer: object = None
    sdk = import_module(_SDK)
    async for message in sdk.query(prompt=_blocks(content), options=options):
        if isinstance(message, sdk.ResultMessage):
            if message.is_error:
                detail = f"{message.subtype} {message.errors} {message.result}"
                raise ModelError(detail)
            answer = message.structured_output
    if not isinstance(answer, dict):
        msg = "model returned no structured object"
        raise ModelError(msg)
    return answer


async def run_model(
    system_prompt: str,
    content: list[dict[str, Any]],
    schema: dict[str, Any],
    *,
    budget_s: float,
) -> dict[str, Any]:
    """The test seam: callers reach the model only through this name."""
    return await bounded_ask(system_prompt, content, schema, budget_s=budget_s)


async def bounded_ask(
    system_prompt: str,
    content: list[dict[str, Any]],
    schema: dict[str, Any],
    *,
    budget_s: float,
) -> dict[str, Any]:
    """Ask the model once; its structured answer (a JSON object).

    Raises:
        ModelTimeoutError: ``budget_s`` seconds passed.
        ModelError: any other failure: login, CLI, API, or a missing answer.
    """
    try:
        async with asyncio.timeout(budget_s):
            return await _ask(system_prompt, content, schema)
    except TimeoutError as err:
        msg = f"model call exceeded {budget_s:g} s"
        raise ModelTimeoutError(msg) from err
    except ModelError:
        raise
    except Exception as err:  # SDK/CLI errors have no common base worth naming
        raise ModelError(type(err).__name__) from err
