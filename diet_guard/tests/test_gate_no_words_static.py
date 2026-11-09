"""Static twin of ``test_gate_no_words``: no gate source line can paint a word.

The fake-tk guard only sees strings on the paths a scenario drives. This one
parses every ``_gatelock*.py`` module and fails on any string literal handed
to a painted keyword (``text=``, ``notebook.add(..., text=)``) or written into
a status variable that holds a 2+ letter word, so a new sentence on an
unexercised branch cannot slip in. Runs in CI (no display, no installed gate).
"""

from __future__ import annotations

import ast
from pathlib import Path
import re

from diet_guard.tests.test_gate_no_words import UNITS

PACKAGE = Path(__file__).resolve().parent.parent
WORD = re.compile(r"[^\W\d_]{2,}")
# The window title is the OS-level app name: the one kept proper noun.
APP_NAME = "Diet Gate"
# Variable-backed text sinks: StringVar writes and status setters.
SINKS = {"set", "_set_status", "_set_budget_status", "_set_schedule_status"}


def _literals(node: ast.AST) -> list[str]:
    """Every constant string inside ``node`` (f-string parts included)."""
    return [
        n.value
        for n in ast.walk(node)
        if isinstance(n, ast.Constant) and isinstance(n.value, str)
    ]


def _offences(path: Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    found: list[str] = []
    for call in (n for n in ast.walk(tree) if isinstance(n, ast.Call)):
        painted: list[ast.AST] = [k.value for k in call.keywords if k.arg == "text"]
        name = getattr(call.func, "attr", getattr(call.func, "id", ""))
        if name in SINKS:
            painted.extend(call.args[:1])
        if name == "title":
            continue  # the window title: APP_NAME, checked below
        for node in painted:
            found.extend(
                f"{path.name}:{call.lineno} {lit!r}"
                for lit in _literals(node)
                if set(WORD.findall(lit)) - UNITS
            )
    return found


def test_no_gate_source_paints_a_word() -> None:
    paths = sorted(PACKAGE.glob("_gatelock*.py"))
    assert len(paths) > 20, "the gate modules were not found"
    offences = [o for path in paths for o in _offences(path)]
    assert not offences, "\n" + "\n".join(offences)


def test_the_checker_flags_a_sentence(tmp_path: Path) -> None:
    """Canary: a status sentence and a ``text=`` word are both caught."""
    bad = tmp_path / "_gatelock_x.py"
    bad.write_text(
        'def f(v, w):\n    v.set("Saved.")\n    w.Label(text="Edit")\n'
        '    v.set("OK")\n',
        encoding="utf-8",
    )
    assert len(_offences(bad)) == 3  # "OK" is two letters: a word too


def test_the_window_title_is_the_app_name() -> None:
    source = (PACKAGE / "_gatelock.py").read_text(encoding="utf-8")
    assert f'self.root.title("{APP_NAME}")' in source
