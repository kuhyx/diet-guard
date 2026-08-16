"""Command-line interface for diet_guard.

Examples:
    python -m diet_guard init
    python -m diet_guard ate "big mac"
    python -m diet_guard ate "two slices of pizza" --grams 240
    python -m diet_guard ate "protein shake" --kcal 180
    python -m diet_guard status
    python -m diet_guard averages
    python -m diet_guard undo

The daily budget lives outside the repo (so it is never exposed online) but is
shown freely on this machine: ``status`` and each log print how many calories
are left of the day's budget, plus which meal slots still need logging.
"""

from __future__ import annotations

import sys
from typing import TYPE_CHECKING

from diet_guard._budget import (
    BudgetFileCorruptError,
    BudgetNotInitializedError,
    daily_budget,
)
from diet_guard._budget_derived import protein_target_g
from diet_guard._cli_args import parse_args
from diet_guard._cli_averages import cmd_averages
from diet_guard._cli_gate import cmd_gate
from diet_guard._cli_init import cmd_init
from diet_guard._cli_log import ManualMacroArgs, Portion, cmd_ate
from diet_guard._cli_sync import cmd_sync
from diet_guard._gate import due_slots
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._slots import day_slots, slot_label
from diet_guard._state import (
    entry_kcal,
)
from diet_guard._state_sync import (
    undo_last_today,
)
from diet_guard._state_today import (
    logged_slots_today,
    today_entries,
    today_total_kcal,
    today_total_macros,
)

if TYPE_CHECKING:
    import argparse
    from collections.abc import Callable

# Column width for a meal description in the status listing.
_DESC_WIDTH = 24
# An ISO timestamp formats as "YYYY-MM-DDTHH:MM:SS"; HH:MM is chars 11..16.
_TIME_SLICE = slice(11, 16)


def _emit(text: str = "") -> None:
    """Write one line to stdout.

    A thin wrapper over ``sys.stdout.write`` so genuine CLI output does not
    trip ruff's ``T201`` (no ``print``) without resorting to a suppression.
    """
    sys.stdout.write(f"{text}\n")


def _ask(label: str) -> str:
    """Print a prompt label and return one trimmed line from stdin."""
    _emit(label)
    return sys.stdin.readline().strip()


def _print_summary() -> None:
    """Print today's total and how much of the daily budget is left.

    The budget number is shown here on purpose: it is "hidden" only in the
    sense of never leaving this machine (it lives outside the repo), not hidden
    from the user, who needs it to make portion decisions.
    """
    total = today_total_kcal()
    try:
        budget = daily_budget()
    except BudgetNotInitializedError:
        _emit(
            f"today: {total:g} kcal  (budget not set - run: python -m diet_guard init)",
        )
        return
    except BudgetFileCorruptError:
        _emit(f"today: {total:g} kcal  (budget file corrupt - re-run init)")
        return
    remaining = round(budget - total, 1)
    _emit(f"today: {total:g} kcal  -  {remaining:g} kcal left of {budget:g}")


def _print_entry_line(entry: dict[str, object]) -> None:
    """Print a single log entry as 'HH:MM  desc  kcal  (source)'."""
    time_str = str(entry.get("time", ""))[_TIME_SLICE]
    desc = str(entry.get("desc", "?"))
    source = str(entry.get("source", ""))
    _emit(
        f"  {time_str:>5}  {desc:<{_DESC_WIDTH}.{_DESC_WIDTH}}  "
        f"{entry_kcal(entry):>6.0f} kcal  ({source})",
    )


def _print_slot_status() -> None:
    """Print each meal slot as logged / DUE / upcoming for today."""
    logged = logged_slots_today()
    due = set(due_slots())
    parts: list[str] = []
    for slot in day_slots(current_schedule()):
        if slot in logged:
            mark = "logged"
        elif slot in due:
            mark = "DUE"
        else:
            mark = "upcoming"
        parts.append(f"{slot_label(slot)} {mark}")
    _emit("slots: " + "  ".join(parts))


def _print_macro_status() -> None:
    """Print today's macros so far, with the protein target when it is known.

    Mirrors the gate's dashboard on the command line so "how am I doing" is
    answerable without opening the window.  The protein target only appears once
    the budget has been initialized with a body weight (see ``init``).
    """
    protein, carbs, fat = today_total_macros()
    line = f"macros: P{protein:g} C{carbs:g} F{fat:g} g"
    target = protein_target_g()
    if target is not None:
        remaining = round(target - protein, 1)
        line += f"  -  protein {protein:g}/{target:g} g ({remaining:g} left)"
    _emit(line)


def _cmd_status() -> int:
    """Print today's entries, per-slot status, macros, and the budget remaining."""
    entries = today_entries()
    for entry in entries:
        _print_entry_line(entry)
    if entries:
        _emit("-" * 48)
    _print_slot_status()
    _print_summary()
    _print_macro_status()
    return 0


def _cmd_undo() -> int:
    """Remove today's most recent entry and report what was removed."""
    removed = undo_last_today()
    if removed is None:
        _emit("nothing to undo today.")
        return 0
    desc = str(removed.get("desc", "?"))
    _emit(f"removed: {desc}  ({entry_kcal(removed):g} kcal)")
    _print_summary()
    return 0


def _dispatch_ate(args: argparse.Namespace) -> int:
    """Marshal ``ate``'s flags into value objects, then log the meal."""
    return cmd_ate(
        _emit,
        _print_summary,
        args.description,
        Portion(grams=args.grams, count=args.count, per_grams=args.per),
        ManualMacroArgs(
            kcal=args.kcal,
            protein=args.protein,
            carbs=args.carbs,
            fat=args.fat,
        ),
    )


def _dispatch_gate(args: argparse.Namespace) -> int:
    """Run the gate subcommand with its two flags."""
    return cmd_gate(_emit, check=args.check, demo=args.demo)


# A table rather than an if-chain: the chain grew a return per subcommand and
# tripped ruff's return-count limit at the seventh, and a table also has no
# unreachable trailing branch for the 100%-coverage gate to chase.
_COMMANDS: dict[str, Callable[[argparse.Namespace], int]] = {
    "init": lambda _args: cmd_init(_emit, _ask),
    "ate": _dispatch_ate,
    "status": lambda _args: _cmd_status(),
    "averages": lambda _args: cmd_averages(_emit),
    "sync": lambda _args: cmd_sync(_emit),
    "gate": _dispatch_gate,
    "undo": lambda _args: _cmd_undo(),
}


def main(argv: list[str] | None = None) -> int:
    """Dispatch a diet_guard subcommand.

    Args:
        argv: Argument list (defaults to ``sys.argv[1:]``).

    Returns:
        A process exit code (0 on success).
    """
    args = parse_args(sys.argv[1:] if argv is None else argv)
    return _COMMANDS[args.command](args)
