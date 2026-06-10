"""Command-line interface for diet_guard.

Examples:
    python -m python_pkg.diet_guard init
    python -m python_pkg.diet_guard ate "big mac"
    python -m python_pkg.diet_guard ate "two slices of pizza" --grams 240
    python -m python_pkg.diet_guard ate "protein shake" --kcal 180
    python -m python_pkg.diet_guard status
    python -m python_pkg.diet_guard undo

The daily budget lives outside the repo (so it is never exposed online) but is
shown freely on this machine: ``status`` and each log print how many calories
are left of the day's budget, plus which meal slots still need logging.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import sys

from python_pkg.diet_guard._budget import (
    Biometrics,
    BudgetLockedError,
    BudgetNotInitializedError,
    BudgetSealBrokenError,
    compute_target_budget,
    daily_budget,
    lock_command,
    protein_target_g,
    seal_budget,
    unlock_command,
)
from python_pkg.diet_guard._foodbank import remember_food
from python_pkg.diet_guard._gate import due_slots, gate_is_due
from python_pkg.diet_guard._gatelock import (
    MealGate,
    acquire_gate_lock,
    release_gate_lock,
    wait_for_display,
)
from python_pkg.diet_guard._portions import (
    DEFAULT_ITEM_GRAMS,
    estimate_unit_grams,
)
from python_pkg.diet_guard._resolve import ManualMacros, resolve_nutrition
from python_pkg.diet_guard._slots import current_slot, day_slots, slot_label
from python_pkg.diet_guard._state import (
    entry_kcal,
    log_meal,
    logged_slots_today,
    now_local,
    today_entries,
    today_total_kcal,
    today_total_macros,
    undo_last_today,
)

# Column width for a meal description in the status listing.
_DESC_WIDTH = 24
# An ISO timestamp formats as "YYYY-MM-DDTHH:MM:SS"; HH:MM is chars 11..16.
_TIME_SLICE = slice(11, 16)
# Accepted answers for the sex prompt that map to the male BMR constant.
_MALE_ANSWERS = {"m", "male"}
_FEMALE_ANSWERS = {"f", "female"}


@dataclass(frozen=True)
class _ManualMacros:
    """User-supplied calories/macros for ``ate``, all optional.

    Grouping these keeps :func:`_cmd_ate` within the argument-count limit and
    makes "manual values were supplied" a single, testable value object.

    Attributes:
        kcal: Calories entered manually (None means look the food up instead).
        protein: Protein grams, recorded alongside ``kcal``.
        carbs: Carbohydrate grams, recorded alongside ``kcal``.
        fat: Fat grams, recorded alongside ``kcal``.
    """

    kcal: float | None
    protein: float | None
    carbs: float | None
    fat: float | None


@dataclass(frozen=True)
class _Portion:
    """How much was eaten and the basis for any typed macros.

    Grouped so :func:`_cmd_ate` stays within the argument-count limit.

    Attributes:
        grams: Explicit grams eaten, or None.
        count: Number of items eaten (an alternative to ``grams``), or None.
        per_grams: Reference weight the typed macros are stated for (e.g. 100
            for a per-100 g label), or None to treat the macros as totals.
    """

    grams: float | None
    count: float | None
    per_grams: float | None


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


def _parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse diet_guard CLI arguments."""
    parser = argparse.ArgumentParser(
        prog="diet_guard",
        description="Log calories and check your daily budget.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser(
        "init",
        help="Compute your daily budget from biometrics and seal it (hidden).",
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
            f"today: {total:g} kcal  "
            "(budget not set - run: python -m python_pkg.diet_guard init)",
        )
        return
    except BudgetSealBrokenError:
        _emit(f"today: {total:g} kcal  (budget seal broken - re-run init)")
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


def _read_init_inputs() -> tuple[Biometrics, float, float] | None:
    """Prompt for biometrics on stdin; return (bio, activity, deficit) or None.

    Returns None (after printing why) on any unparsable or out-of-range input,
    so a typo never seals a wrong budget.
    """
    try:
        weight = float(_ask("weight in kg:"))
        height = float(_ask("height in cm:"))
        age = float(_ask("age in years:"))
        sex_raw = _ask("sex (m/f):").lower()
        activity = float(
            _ask(
                "activity factor "
                "(1.2 sedentary / 1.375 light / 1.55 moderate / 1.725 active):",
            ),
        )
        deficit = float(_ask("daily deficit in kcal (e.g. 200):"))
    except ValueError:
        _emit("that was not a number; nothing was sealed.")
        return None

    if sex_raw in _MALE_ANSWERS:
        is_male = True
    elif sex_raw in _FEMALE_ANSWERS:
        is_male = False
    else:
        _emit('sex must be "m" or "f"; nothing was sealed.')
        return None

    bio = Biometrics(
        weight_kg=weight,
        height_cm=height,
        age_years=age,
        is_male=is_male,
    )
    return bio, activity, deficit


def _cmd_init() -> int:
    """Compute the budget from biometrics and seal it, printing no number."""
    inputs = _read_init_inputs()
    if inputs is None:
        return 2
    bio, activity, deficit = inputs
    budget = compute_target_budget(
        bio,
        activity_factor=activity,
        deficit_kcal=deficit,
    )
    try:
        seal_budget(budget, weight_kg=bio.weight_kg)
    except BudgetLockedError:
        _emit("the budget is locked; unlock it first, then re-run init:")
        _emit(f"  {unlock_command()}")
        return 1
    _emit("budget computed from your biometrics and sealed - the number is")
    _emit("intentionally not shown.")
    _emit(f"to lock it against casual edits, run:  {lock_command()}")
    return 0


def _eaten_grams(
    description: str,
    portion: _Portion,
) -> tuple[float | None, str | None]:
    """Resolve how many grams were eaten, plus a note if a weight was assumed.

    A count of items is turned into grams via the staple's unit weight; an
    unknown item falls back to a default weight, with a note so the estimate is
    never silent.

    Args:
        description: The food name (used to look up a per-item weight).
        portion: The user's portion inputs.

    Returns:
        ``(grams, note)`` where ``grams`` may be None (no portion given) and
        ``note`` is a one-line caveat to print, or None.
    """
    if portion.count is not None:
        unit = estimate_unit_grams(description)
        if unit is None:
            return (
                portion.count * DEFAULT_ITEM_GRAMS,
                f"(assumed {DEFAULT_ITEM_GRAMS:g} g per item; "
                "pass --grams to be exact)",
            )
        return portion.count * unit, None
    return portion.grams, None


def _cmd_ate(description: str, portion: _Portion, macros: _ManualMacros) -> int:
    """Resolve and log a meal, tag its slot, bank it, then print the total.

    Resolution order is manual, then food bank, then the staple table, then
    Open Food Facts (see :func:`resolve_nutrition`).  A per-item count or a
    per-reference macro basis is converted to the amount actually eaten first,
    and the food is remembered so next time it is served from local history.
    """
    eaten, note = _eaten_grams(description, portion)
    if note is not None:
        _emit(note)
    manual_macros = (
        ManualMacros(
            kcal=macros.kcal,
            protein=macros.protein or 0.0,
            carbs=macros.carbs or 0.0,
            fat=macros.fat or 0.0,
            per_grams=portion.per_grams,
        )
        if macros.kcal is not None
        else None
    )
    nutrition = resolve_nutrition(
        description,
        grams=eaten,
        manual_macros=manual_macros,
    )
    if nutrition is None:
        _emit(
            f'no food bank, staple, or Open Food Facts match for "{description}". '
            "re-run with --kcal <number> to log it manually.",
        )
        return 1
    log_meal(description, nutrition, current_slot(now_local()))
    remember_food(description, nutrition)
    macro_str = f"P{nutrition.protein_g:g} C{nutrition.carbs_g:g} F{nutrition.fat_g:g}"
    portion_str = f"{nutrition.grams:g} g" if nutrition.grams else "portion n/a"
    _emit(
        f"logged: {description}  {nutrition.kcal:g} kcal  "
        f"({macro_str})  [{nutrition.source}, {portion_str}]",
    )
    _print_summary()
    return 0


def _print_slot_status() -> None:
    """Print each meal slot as logged / DUE / upcoming for today."""
    logged = logged_slots_today()
    due = set(due_slots())
    parts: list[str] = []
    for slot in day_slots():
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


def _cmd_gate(*, check: bool, demo: bool) -> int:
    """Run the log-to-unlock gate.

    Three modes: ``--check`` is a headless decision (no window) whose exit code
    a timer reads; ``--demo`` always shows a safe demo window; bare ``gate``
    shows the real lock only when one is due.  A flock guard stops a second
    window from stacking on top of the first, and a window-opening mode first
    waits for the X display so a session-start launch never crashes unshown.

    Args:
        check: Headless mode -- print and return an exit code, open no window.
        demo: Use safe demo mode (local grab + close button) for the window.

    Returns:
        For ``--check``: 0 if not due, 1 if a lock is due.  Otherwise 0.
    """
    if check:
        due = gate_is_due()
        _emit("due (a lock is warranted)" if due else "ok (no lock needed)")
        return 1 if due else 0
    if not demo and not gate_is_due():
        _emit("ok - no lock needed right now.")
        return 0
    handle = acquire_gate_lock()
    if handle is None:
        _emit("the gate is already running.")
        return 0
    try:
        # At session start the timer can fire before the X display/auth cookie
        # is ready; wait it out so the window opens instead of crashing on a
        # "couldn't connect to display" TclError (see _gatelock.wait_for_display).
        if not wait_for_display():
            _emit("display not ready yet; will retry on the next timer tick.")
            return 0
        MealGate(demo_mode=demo).run()
    finally:
        release_gate_lock(handle)
    return 0


def main(argv: list[str] | None = None) -> int:
    """Dispatch a diet_guard subcommand.

    Args:
        argv: Argument list (defaults to ``sys.argv[1:]``).

    Returns:
        A process exit code (0 on success).
    """
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    if args.command == "init":
        return _cmd_init()
    if args.command == "ate":
        macros = _ManualMacros(
            kcal=args.kcal,
            protein=args.protein,
            carbs=args.carbs,
            fat=args.fat,
        )
        portion = _Portion(
            grams=args.grams,
            count=args.count,
            per_grams=args.per,
        )
        return _cmd_ate(args.description, portion, macros)
    if args.command == "status":
        return _cmd_status()
    if args.command == "gate":
        return _cmd_gate(check=args.check, demo=args.demo)
    return _cmd_undo()
