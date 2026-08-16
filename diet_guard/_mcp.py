"""MCP (Model Context Protocol) server for diet_guard.

Exposes diet_guard's read surface and one *gated* write action as typed MCP
tools, so an MCP client (Claude Code and its subagents) can query today's
intake and -- with explicit confirmation -- log a meal without shelling out to
the interactive CLI.

Run via the dedicated venv that has the ``mcp`` extra installed::

    ~/.venvs/diet-guard-mcp/bin/python -m diet_guard._mcp

(see ``scripts/setup_mcp.sh`` and the repo-root ``.mcp.json``).

Safety invariants (do not break when adding tools):
  * **stdout is the JSON-RPC channel.** This module and every function a tool
    calls must never write to stdout. All logging is routed to STDERR below,
    and tools call only stdout-free leaf helpers (never the ``_cmd_*`` /
    ``main`` CLI handlers, which write to stdout, read stdin, and ``sys.exit``).
  * **The daily budget number never leaves via this interface.** No tool
    returns the raw budget, the remaining-budget number, the stored body
    weight, the protein target, or the ``.budget`` file: an automated caller
    should not be handed the exact number to reason about or help game,
    even though the number itself is freely visible to the human via the
    CLI/GUI and the phone app. Read tools expose only today's *consumed*
    kcal / macros and the qualitative :func:`consumption_band` string.
  * **No secret ever leaves.** There is no tool that reads the shared HMAC key,
    the sync token, or any file under ``/etc``.
  * **Writes are gated.** The write tool defaults to a dry-run preview and
    mutates only when ``confirm=True``. It must never be added to a permission
    allowlist (a subagent could then bypass the human), and it never raises --
    a failed write degrades to ``{"ok": false, ...}``.
"""

from __future__ import annotations

import sys
from typing import Any

from pydantic import BaseModel

# Importing these IS what registers the read tools: the module-level
# ``@mcp.tool`` decorators in ``_mcp_read`` run against the shared singleton at
# import time. They are re-exported via ``__all__`` rather than imported bare so
# the names are genuinely used -- drop this and the server starts write-only.
from diet_guard._mcp_read import get_averages, get_slots, get_status, list_today
from diet_guard._mcp_server import APPENDS, logger, mcp
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._resolve import ManualMacros, resolve_nutrition
from diet_guard._slots import slot_for_log
from diet_guard._state import (
    log_meal as record_meal,
)
from diet_guard._state import now_local
from diet_guard._sync_events import publish_after_log

# ──────────────────────────────────────────────────────────────
# Gated write tool (preview unless confirm=True; NEVER allowlist this)
# ──────────────────────────────────────────────────────────────


class Macros(BaseModel):
    """Manually-entered nutrition for one meal.

    Bundled into a single parameter so ``log_meal`` stays under the arg-count
    limits without any lint suppression (mirrors the ``_ManualMacros`` grouping
    the CLI uses for the same reason). ``kcal`` is required; when this is
    supplied to ``log_meal``, the food-bank / Open Food Facts lookups are
    skipped and the meal is logged exactly as given (fully offline).
    """

    kcal: float
    protein: float = 0.0
    carbs: float = 0.0
    fat: float = 0.0


@mcp.tool(title="Log a meal (gated write)", annotations=APPENDS)
def log_meal(
    description: str,
    grams: float | None = None,
    macros: Macros | None = None,
    slot: int | None = None,
    *,
    confirm: bool = False,
) -> dict[str, Any]:
    """Resolve and (on confirm) log a meal to today's food log (gated write).

    With ``confirm=False`` (the default) this performs **no** mutation: it
    resolves the nutrition and reports the slot the entry would satisfy, so the
    caller can review before applying. Call again with ``confirm=True`` to
    actually append the entry. Nutrition is resolved exactly as the CLI's
    ``ate`` does -- manual ``macros`` first (when given), then the local food
    bank / staple table, then Open Food Facts -- so passing ``macros`` keeps the
    write fully offline and deterministic.

    The write degrades gracefully: if the food log cannot be written it returns
    ``{"ok": false, ...}`` rather than raising, so the stdio server survives.
    A missing shared HMAC key is not an error -- :func:`record_meal` then stores
    the entry unsigned (and it is still accepted on read on a keyless system).

    Args:
        description: Free-text meal description, e.g. ``"big mac"``.
        grams: Portion size in grams (rescales every nutrition source).
        macros: Manually-entered nutrition (``kcal`` plus optional
            protein/carbs/fat). When given, lookups are skipped and the meal is
            logged exactly as specified.
        slot: The meal-slot hour to satisfy; when omitted (or None) it falls
            back to ``slot_for_log``, which clamps to a real hour rather than
            returning None, so the entry always satisfies some slot.
        confirm: Set ``True`` to actually append the entry; otherwise preview.

    Returns:
        A preview or applied result dict; ``{"ok": false, "reason": ...}`` when
        the food cannot be resolved or the log cannot be written.
    """
    manual_macros = (
        ManualMacros(
            kcal=macros.kcal,
            protein=macros.protein,
            carbs=macros.carbs,
            fat=macros.fat,
        )
        if macros is not None
        else None
    )
    nutrition = resolve_nutrition(description, grams=grams, manual_macros=manual_macros)
    if nutrition is None:
        return {
            "ok": False,
            "reason": (
                f'could not resolve "{description}" from the food bank, staples, '
                "or Open Food Facts. Pass kcal=<number> to log it manually."
            ),
        }
    target_slot = (
        slot if slot is not None else slot_for_log(now_local(), current_schedule())
    )
    resolved = {
        "kcal": nutrition.kcal,
        "protein_g": nutrition.protein_g,
        "carbs_g": nutrition.carbs_g,
        "fat_g": nutrition.fat_g,
        "grams": nutrition.grams,
        "source": nutrition.source,
    }
    if not confirm:
        return {
            "ok": True,
            "preview": True,
            "action": "log_meal",
            "description": description,
            "resolved": resolved,
            "target_slot": target_slot,
            "confirm_required": True,
        }
    try:
        entry = record_meal(description, nutrition, target_slot)
    except OSError as exc:  # never crash the stdio server on a write failure
        logger.warning("log_meal write failed: %s", exc)
        return {"ok": False, "reason": "could not write the food log."}
    logger.info("log_meal applied: %s (%g kcal)", description, nutrition.kcal)
    # Same rule as the CLI: publish on the event, not on a clock. Fail-closed,
    # so a sync outage still reports the local write as applied.
    published = publish_after_log() is None
    return {
        "ok": True,
        "applied": True,
        "action": "log_meal",
        "description": description,
        "logged": resolved,
        "target_slot": target_slot,
        "signed": "hmac" in entry,
        "published": published,
    }


def main() -> None:
    """Run the MCP server over stdio (STDOUT = JSON-RPC, STDERR = logs)."""
    logger.info("Starting diet-guard MCP server (python=%s)", sys.executable)
    mcp.run()  # pragma: no cover


if __name__ == "__main__":
    main()


#: Re-exported so ``from diet_guard._mcp import get_status`` keeps working for
#: the tests and any client that imported them from here before the split.
__all__ = [
    "Macros",
    "get_averages",
    "get_slots",
    "get_status",
    "list_today",
    "log_meal",
    "main",
]
