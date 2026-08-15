"""Argument parsing for the diet_guard CLI.

Split out of :mod:`diet_guard._cli` to hold the repo's 250-line cap. This is
the declarative half -- every subcommand and flag the CLI accepts -- kept apart
from the handlers that act on them, so adding a flag never grows a file that
also contains logic.

Subparsers owned by a sibling handler register themselves through their own
module (``register_averages_subparser``, ``register_sync_subparser``) rather
than being spelled out here, so a subcommand's flags live next to its code.
"""

from __future__ import annotations

import argparse

from diet_guard._cli_averages import register_averages_subparser
from diet_guard._cli_sync import register_sync_subparser


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse diet_guard CLI arguments."""
    parser = argparse.ArgumentParser(
        prog="diet_guard",
        description="Log calories and check your daily budget.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser(
        "init",
        help="Compute your starting daily budget from biometrics.",
    )

    ate = sub.add_parser("ate", help="Log a meal you just ate.")
    ate.add_argument("description", help='What you ate, e.g. "big mac".')
    ate.add_argument(
        "--grams",
        type=float,
        default=None,
        help="Portion size in grams (default: OFF serving size, else 100 g).",
    )
    ate.add_argument(
        "--kcal",
        type=float,
        default=None,
        help="Calories entered manually; skips the food bank and OFF lookup.",
    )
    ate.add_argument(
        "--protein",
        type=float,
        default=None,
        help="Protein in grams (recorded with --kcal to seed the food bank).",
    )
    ate.add_argument(
        "--carbs",
        type=float,
        default=None,
        help="Carbohydrate in grams (recorded with --kcal).",
    )
    ate.add_argument(
        "--fat",
        type=float,
        default=None,
        help="Fat in grams (recorded with --kcal).",
    )
    ate.add_argument(
        "--per",
        type=float,
        default=None,
        help="Grams the macros are stated for (e.g. 100 for a per-100 g label);"
        " the typed macros are scaled from this to how much you ate.",
    )
    ate.add_argument(
        "--count",
        type=float,
        default=None,
        help="Number of items eaten (e.g. 5 apples) instead of --grams;"
        " multiplied by the staple's unit weight.",
    )

    sub.add_parser("status", help="Show today's calories and budget band.")
    sub.add_parser("undo", help="Remove today's most recent entry.")
    register_averages_subparser(sub)
    register_sync_subparser(sub)

    gate = sub.add_parser(
        "gate",
        help="Log-to-unlock screen gate (intended to be run by a timer).",
    )
    gate.add_argument(
        "--check",
        action="store_true",
        help="Headless: exit 0 if NOT due, 1 if a lock is due. Prints, no window.",
    )
    gate.add_argument(
        "--demo",
        action="store_true",
        help="Show the lock in safe demo mode (local grab + close button).",
    )
    return parser.parse_args(argv)
