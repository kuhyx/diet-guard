"""CLI handler for the ``kuchnia`` subcommand.

Fetches today's catering delivery, banks the dishes, and -- only with an
explicit confirmation -- logs them.  Dry run by default: the whole point of
this feature is that a *delivered* meal is not an *eaten* meal, so writing
entries is always something the user asks for, never something that happens
because a command ran.

Structured like :mod:`diet_guard._cli_prune`: lazy attributes so registering
the subparser drags no HTTP stack into every other command, ``emit`` passed in
rather than imported, and an int exit code.
"""

from __future__ import annotations

from importlib import import_module
import sys
from typing import TYPE_CHECKING

from diet_guard._kuchnia_spread import assign_slots
from diet_guard._meal_schedule_store import current_schedule
from diet_guard._slots import day_slots
from diet_guard._state import now_local

if TYPE_CHECKING:  # pragma: no cover - typing only
    import argparse
    from collections.abc import Callable

# ``_kuchnia_import`` reaches ``requests``; registering this subparser must not
# make every other command pay for an HTTP stack.
_LAZY_ATTRS = {
    "refresh_delivery": ("diet_guard._kuchnia_import", "refresh_delivery"),
    "log_dishes": ("diet_guard._kuchnia_log", "log_dishes"),
}


def __getattr__(name: str) -> object:
    """Resolve the deferred import helpers on first attribute access."""
    target = _LAZY_ATTRS.get(name)
    if target is None:
        msg = f"module {__name__!r} has no attribute {name!r}"
        raise AttributeError(msg)
    module_name, attr = target
    return getattr(import_module(module_name), attr)


def register_kuchnia_subparser(sub: argparse._SubParsersAction) -> None:
    """Register the ``kuchnia`` subcommand on ``sub``."""
    kuchnia = sub.add_parser(
        "kuchnia",
        help="Import today's Kuchnia Wikinga delivery into the food bank.",
    )
    kuchnia.add_argument(
        "--log",
        action="store_true",
        help="Also log the dishes as eaten (asks first unless --yes).",
    )
    kuchnia.add_argument(
        "--yes",
        action="store_true",
        help="Skip the confirmation prompt for --log (for scripting).",
    )


def cmd_kuchnia(
    emit: Callable[[str], None],
    ask: Callable[[str], str],
    *,
    log: bool,
    yes: bool,
) -> int:
    """Import today's delivery; with ``--log``, offer to log it too.

    Args:
        emit: A one-line output sink.
        ask: A prompt function (``_cli._ask``), used only for the confirmation.
        log: Offer to write log entries as well as banking the dishes.
        yes: Skip the confirmation prompt.

    Returns:
        0 on success, 1 when the catering panel could not be read.
    """
    module = sys.modules[__name__]
    # now_local() is the repo's tz-aware clock; its date is the same local
    # calendar day the log is keyed by.
    today = now_local().date()
    dishes, reason = module.refresh_delivery(today)
    if reason is not None:
        emit(f"catering unavailable: {reason}")
        return 1
    if not dishes:
        emit("no catering delivery today.")
        return 0

    slotted = assign_slots(dishes, day_slots(current_schedule()))
    emit(f"{len(dishes)} dish(es) delivered today, banked:")
    for item in slotted:
        emit(
            f"  {item.slot:02d}:00  {item.dish.name}  "
            f"({item.dish.kcal:g} kcal, {item.dish.grams:g} g)",
        )
    total = sum(dish.kcal for dish in dishes)
    emit(f"  total: {total:g} kcal")

    if not log:
        emit("not logged -- pass --log to record these as eaten.")
        return 0
    if not yes and ask(f"log all {len(slotted)} as eaten? [y/N] ").strip().lower() != (
        "y"
    ):
        emit("nothing logged.")
        return 0

    written = module.log_dishes(slotted)
    if not written:
        emit("already logged today; nothing to add.")
        return 0
    emit(f"logged {len(written)} meal(s).")
    return 0
