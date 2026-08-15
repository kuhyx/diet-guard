"""Guard: every gate module that builds Tk widgets must be faked in tests.

``_gate_fixtures.fake_tk`` patches ``tk`` on a hand-listed tuple of modules.
That list fails **open**: split a widget builder into a new sibling, forget to
add it, and the gate tests build *real* Tk widgets parented to fake ones. The
symptom is a hang or an error far from the cause -- and on a machine with a
display, a real window during a test run.

Neither of the sweep's other detectors sees this. ``check_patch_targets.py``
only validates dotted paths that still resolve, and the suite's ~8s runtime
only catches network calls. So the invariant is asserted here directly:
*every* ``diet_guard`` module that binds the name ``tk`` is either in the
patch set or explicitly declared widget-free.
"""

from __future__ import annotations

import ast
import pathlib

from diet_guard.tests._gate_fixtures import _GATE_TK_MODULES

#: Modules that bind ``tk`` but build no part of the gate's widget tree, so
#: they never need the shared fake. Each is exempt for a stated reason -- this
#: set is the only sanctioned way out of the patch list.
_NO_WIDGETS = frozenset(
    {
        # Mirror/adapter layer over widgets built elsewhere; constructs none
        # of its own, but does bind ``tk`` at runtime for its ``TclError``
        # suppressions.
        "diet_guard._gatelock_widgetgroups",
        # Display-readiness probe. Builds a throwaway ``tk.Tk()`` to test
        # whether X is reachable -- deliberately NOT part of the gate's widget
        # tree, so the shared fake would defeat the very thing it probes. Its
        # own tests patch ``_gatelock_support.tk`` per-test instead.
        "diet_guard._gatelock_support",
    },
)

_PACKAGE_DIR = pathlib.Path(__file__).resolve().parent.parent


def _is_type_checking(test: ast.expr) -> bool:
    """Whether an ``if`` test is the ``TYPE_CHECKING`` guard."""
    if isinstance(test, ast.Name):
        return test.id == "TYPE_CHECKING"
    return isinstance(test, ast.Attribute) and test.attr == "TYPE_CHECKING"


def _binds_tk(path: pathlib.Path) -> bool:
    """Whether ``path`` binds the name ``tk`` to tkinter at module level.

    That name -- not merely "imports tkinter" -- is what ``fake_tk`` patches,
    so it is what the patch set has to match. A module importing only ``ttk``
    (``_gatelock_calendar_ui``) has no ``tk`` to patch, and listing it would
    raise "does not have the attribute 'tk'".
    """
    tree = ast.parse(path.read_text(encoding="utf-8"), str(path))
    # A TYPE_CHECKING-only import binds nothing at runtime, so there is no
    # attribute for ``patch.object`` to replace -- and listing such a module
    # would raise "does not have the attribute 'tk'". Drop those blocks
    # wholesale before walking, since ``ast.walk`` would otherwise still
    # descend into their bodies.
    tree.body = [
        node
        for node in tree.body
        if not (isinstance(node, ast.If) and _is_type_checking(node.test))
    ]
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == "tkinter" and alias.asname == "tk":
                    return True
        elif (
            isinstance(node, ast.ImportFrom)
            and node.module
            and node.module.split(".")[0] == "tkinter"
        ) and any(alias.asname == "tk" or alias.name == "tk" for alias in node.names):
            return True
    return False


def test_gate_tk_modules_complete() -> None:
    """Every ``tk``-binding diet_guard module is faked or declared widget-free.

    Fails closed: a new widget-building sibling that nobody added to
    ``_GATE_TK_MODULES`` shows up here as a named diff, rather than as a real
    Tk window opening halfway through an unrelated gate test.
    """
    patched = {module.__name__ for module in _GATE_TK_MODULES}
    importers = {
        f"diet_guard.{path.stem}"
        for path in sorted(_PACKAGE_DIR.glob("*.py"))
        if _binds_tk(path)
    }
    unaccounted = importers - patched - _NO_WIDGETS
    assert not unaccounted, (
        "these diet_guard modules bind `tk` but are neither in "
        "_gate_fixtures._GATE_TK_MODULES nor declared widget-free in "
        f"_NO_WIDGETS: {sorted(unaccounted)}"
    )


def test_no_widgets_declarations_are_live() -> None:
    """``_NO_WIDGETS`` names only modules that really do bind ``tk``.

    Keeps the escape hatch honest: once a listed module stops binding ``tk``
    (or is renamed away), its entry is stale and must go, rather than
    lingering as a licence for some future file to skip the patch set.
    """
    importers = {
        f"diet_guard.{path.stem}"
        for path in sorted(_PACKAGE_DIR.glob("*.py"))
        if _binds_tk(path)
    }
    assert importers >= _NO_WIDGETS, (
        "stale _NO_WIDGETS entries (no longer bind `tk`): "
        f"{sorted(_NO_WIDGETS - importers)}"
    )
