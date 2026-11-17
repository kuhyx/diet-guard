"""Estimate one meal with Claude: ``estimate_meal(text, photo) -> Estimate``.

The pure entry point for the relay worker now and the Tk gate later. It never
logs anything: it returns an :class:`~diet_guard._claude_schema.Estimate` or
raises :class:`EstimateError` with the contract's error code, and the caller
decides. Every failure (no login, CLI or API error, timeout, invalid JSON)
is an error, never a guess (fail closed).

The model runs through :func:`diet_guard._claude_sdk.run_model` in an
isolated config dir with the ``diet-food`` skill as its system prompt, the
text and photo as one user message, and the closest food-bank rows.
"""

from __future__ import annotations

import asyncio
import base64
from typing import Any, Final

from diet_guard import _claude_sandbox, _claude_sdk
from diet_guard._claude_bank import bank_rows
from diet_guard._claude_schema import (
    SCHEMA,
    Estimate,
    InvalidEstimateError,
    parse_estimate,
)

#: Contract error codes (``docs/DOCS-claude-relay.md`` section 3).
TIMEOUT: Final = "estimate_timeout"
FAILED: Final = "estimate_failed"
INVALID: Final = "estimate_invalid"

#: Wall-clock budget for one model call; the contract's 45 s.
BUDGET_S: Final = 45.0


class EstimateError(Exception):
    """The meal could not be estimated; ``code`` is the contract's code."""

    def __init__(self, code: str, message: str) -> None:
        """Carry the contract ``code`` and a log-only ``message``."""
        super().__init__(message)
        self.code = code


def _content(text: str | None, photo: bytes | None) -> list[dict[str, Any]]:
    """The user message: the typed meal, the bank rows, the photo."""
    rows = bank_rows(text)
    parts = [f"Meal as typed: {text.strip()}" if text and text.strip() else "No text."]
    if rows:
        parts.append("Food bank (name | grams | kcal | macros per logged portion):")
        parts.extend(rows)
    blocks: list[dict[str, Any]] = [{"type": "text", "text": "\n".join(parts)}]
    if photo is not None:
        data = base64.b64encode(photo).decode("ascii")
        source = {"type": "base64", "media_type": "image/jpeg", "data": data}
        blocks.append({"type": "image", "source": source})
    return blocks


async def estimate_meal_async(text: str | None, photo: bytes | None) -> Estimate:
    """Estimate one meal; for callers already inside an event loop.

    Raises:
        ValueError: neither ``text`` nor ``photo`` was given.
        EstimateError: the model failed, timed out or answered nonsense.
    """
    if not (text and text.strip()) and photo is None:
        msg = "nothing to estimate: no text and no photo"
        raise ValueError(msg)
    prompt = await asyncio.to_thread(_claude_sandbox.skill_text)
    content = await asyncio.to_thread(_content, text, photo)
    try:
        answer = await _claude_sdk.run_model(prompt, content, SCHEMA, budget_s=BUDGET_S)
    except _claude_sdk.ModelTimeoutError as err:
        raise EstimateError(TIMEOUT, str(err)) from err
    except _claude_sdk.ModelError as err:
        raise EstimateError(FAILED, str(err)) from err
    try:
        return parse_estimate(answer)
    except InvalidEstimateError as err:
        raise EstimateError(INVALID, str(err)) from err


def estimate_meal(text: str | None, photo: bytes | None) -> Estimate:
    """Estimate one meal from a description and/or a JPEG photo (blocking).

    Not callable from inside a running event loop; use
    :func:`estimate_meal_async` there.

    Raises:
        ValueError: neither ``text`` nor ``photo`` was given.
        EstimateError: the model failed, timed out or answered nonsense.
    """
    return asyncio.run(estimate_meal_async(text, photo))
