"""CLI handler for the ``claude-worker`` subcommand.

The relay worker needs ``claude_agent_sdk``, ``rtdb_relay`` and ``httpx``,
which system Python only gains after the install step. Importing the worker
here would make every command (the gate included) fail at load time on a
machine that has not run it -- the 2026-06-19 outage shape -- so the worker
module is imported only when this subcommand actually runs.
"""

from __future__ import annotations

from importlib import import_module
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import argparse


def register_claude_subparser(sub: argparse._SubParsersAction) -> None:
    """Register the ``claude-worker`` subcommand on ``sub``."""
    sub.add_parser(
        "claude-worker",
        help="Serve the phone's 'send to Claude' meal requests (long-running).",
    )


def cmd_claude_worker() -> int:
    """Run the relay worker until it is stopped; its exit code."""
    return import_module("diet_guard._claude_relay").main()
