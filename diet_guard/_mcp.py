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
  * **The daily budget number never leaves.** No tool returns the raw budget,
    the remaining-budget number, the stored body weight, the protein target, or
    the sealed ``.budget`` file: those would let a caller back out the
    deliberately-hidden budget. Read tools expose only today's *consumed* kcal /
    macros and the qualitative :func:`consumption_band` string.
  * **No secret ever leaves.** There is no tool that reads the shared HMAC key,
    the sync token, or any file under ``/etc``.
  * **Writes are gated.** The write tool defaults to a dry-run preview and
    mutates only when ``confirm=True``. It must never be added to a permission
    allowlist (a subagent could then bypass the human), and it never raises --
    a failed write degrades to ``{"ok": false, ...}``.
"""

from __future__ import annotations

import logging
import sys
from typing import Any

from mcp.server.fastmcp import FastMCP
from pydantic import BaseModel

from diet_guard._budget import BudgetError
from diet_guard._gate import due_slots
from diet_guard._resolve import ManualMacros, resolve_nutrition
from diet_guard._slots import current_slot, day_slots, slot_label
from diet_guard._state import (
    consumption_band,
    logged_slots_today,
    now_local,
    today_entries,
    today_total_kcal,
    today_total_macros,
)
from diet_guard._state import (
    log_meal as record_meal,
)

# Log to STDERR only -- STDOUT carries the MCP JSON-RPC protocol frames, so a
# single stray stdout write would corrupt the stream and kill the session.
logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="%(asctime)s [%(levelname)s] diet-guard-mcp: %(message)s",
)
logger = logging.getLogger(__name__)

mcp = FastMCP("diet-guard")


def _entry_view(entry: dict[str, object]) -> dict[str, Any]:
    """Project a stored log entry to a safe, JSON-friendly summary.

    Deliberately drops the ``hmac`` field and any unknown keys: the signature
    is internal integrity metadata, not something a client needs.

    Args:
        entry: A stored food-log entry.

    Returns:
        A flat dict of the display-relevant fields.
    """
    return {
        "time": entry.get("time"),
        "desc": entry.get("desc"),
        "kcal": entry.get("kcal"),
        "protein_g": entry.get("protein_g"),
        "carbs_g": entry.get("carbs_g"),
        "fat_g": entry.get("fat_g"),
        "grams": entry.get("grams"),
        "source": entry.get("source"),
        "slot": entry.get("slot"),
    }


# ──────────────────────────────────────────────────────────────
# Read tools (consumed intake + qualitative band only; NEVER the budget number)
# ──────────────────────────────────────────────────────────────


@mcp.tool()
def get_status() -> dict[str, Any]:
    """Return today's intake status without ever revealing the daily budget.

    Reports the calories and macros *consumed* so far, the qualitative
    :func:`consumption_band` (``"on track"`` / ``"approaching limit"`` /
    ``"OVER BUDGET"``, or ``None`` when no budget is sealed yet), and the
    meal-slot picture (which slots are due, which are already logged, and the
    current slot). The raw budget number is intentionally withheld -- only the
    band is exposed, mirroring how the CLI status shows a label to an automated
    caller rather than the anchor number.
    """
    try:
        band: str | None = consumption_band()
    except BudgetError:
        # No budget sealed (or a broken seal): surface the absence, not a number.
        band = None
    return {
        "consumed_kcal": today_total_kcal(),
        "consumed_macros_g": _macros_dict(today_total_macros()),
        "consumption_band": band,
        "budget_initialized": band is not None,
        "due_slots": [slot_label(slot) for slot in due_slots()],
        "logged_slots": sorted(logged_slots_today()),
        "current_slot": current_slot(now_local()),
    }


@mcp.tool()
def list_today() -> dict[str, Any]:
    """List today's logged meals (valid entries only), newest last.

    Returns the per-entry description, calories, macros, portion, source, and
    slot -- the same data the CLI ``status`` listing renders, minus the internal
    HMAC signature.
    """
    entries = today_entries()
    return {
        "count": len(entries),
        "entries": [_entry_view(entry) for entry in entries],
    }


@mcp.tool()
def get_slots() -> dict[str, Any]:
    """Return the day's fixed meal slots and which one is current.

    Pure schedule information (08:00 / 12:00 / 16:00 / 20:00 by default) with no
    budget or intake data attached.
    """
    return {
        "day_slots": [
            {"hour": slot, "label": slot_label(slot)} for slot in day_slots()
        ],
        "current_slot": current_slot(now_local()),
    }


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


@mcp.tool()
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
        slot: The meal-slot hour to satisfy; defaults to the current elapsed
            slot (may be ``None`` early in the day, logging calories only).
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
    target_slot = slot if slot is not None else current_slot(now_local())
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
    return {
        "ok": True,
        "applied": True,
        "action": "log_meal",
        "description": description,
        "logged": resolved,
        "target_slot": target_slot,
        "signed": "hmac" in entry,
    }


def _macros_dict(macros: tuple[float, float, float]) -> dict[str, float]:
    """Return a ``(protein, carbs, fat)`` triple as a labelled dict."""
    protein, carbs, fat = macros
    return {"protein": protein, "carbs": carbs, "fat": fat}


def main() -> None:
    """Run the MCP server over stdio (STDOUT = JSON-RPC, STDERR = logs)."""
    logger.info("Starting diet-guard MCP server (python=%s)", sys.executable)
    mcp.run()  # pragma: no cover


if __name__ == "__main__":
    main()
