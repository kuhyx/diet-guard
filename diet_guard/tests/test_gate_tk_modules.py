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
import tkinter as tk
from unittest.mock import MagicMock

from diet_guard import (
    _gatelock_calendar,
    _gatelock_calendar_ui,
    _gatelock_ui,
    _gatelock_widgetgroups,
)
from diet_guard.tests._gate_fixtures import _GATE_TK_MODULES, fake_tk
from diet_guard.tests._tk_fakes import _FAKE_TK, _FAKE_TTK, _FakeTclError

#: Modules that bind ``tk`` but build no part of the gate's widget tree, so
#: they never need the shared fake. Each is exempt for a stated reason -- this
#: set is the only sanctioned way out of the patch list.
_NO_WIDGETS = frozenset(
    {
        # Mirror/adapter layer over widgets built elsewhere; constructs none
        # of its own. It binds real ``tk`` only to name ``tk.TclError`` in
        # its dead-copy suppressions, which is why ``_FakeTclError``
        # subclasses the real one -- see the last test in this file.
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


def test_fake_tk_actually_replaces_real_tkinter() -> None:
    """Inside ``fake_tk()``, every listed module's ``tk`` really is the fake.

    The list-completeness test above proves each module is *named* in the patch
    set. It cannot prove the patch swaps in something that is not real tkinter:
    if ``_FAKE_TK`` were ever imported from the wrong place after a split of
    ``_tk_fakes.py``, or silently became an alias of the real module, every
    listed module would still be "patched" and the suite would still pass --
    while building real widgets. So assert the identity directly, inside the
    context manager, which is the only place it is true.
    """
    assert _FAKE_TK is not tk, "_FAKE_TK must not be the real tkinter module"

    with fake_tk():
        wrong = [
            module.__name__ for module in _GATE_TK_MODULES if module.tk is not _FAKE_TK
        ]
        assert not wrong, f"fake_tk() left real tkinter in place for: {wrong}"
        assert _gatelock_calendar.ttk is _FAKE_TTK
        assert _gatelock_calendar_ui.ttk is _FAKE_TTK

    # ...and is restored afterwards, so the fake cannot leak into other tests.
    assert _gatelock_ui.tk is tk


def test_fake_tclerror_is_catchable_as_the_real_one() -> None:
    """The fake ``TclError`` must satisfy ``except tkinter.TclError``.

    Not every module that catches a dead-widget error is in the patch set:
    ``_gatelock_widgetgroups`` is deliberately exempt (it constructs no
    widgets), so its ``contextlib.suppress(tk.TclError)`` names the genuine
    class. If the fake did not inherit from it, a fake-tk test raising
    ``_FakeTclError`` would sail straight through that suppression -- the
    "a monitor vanished mid-update" paths would be untested against the error
    the tests actually raise, and would raise through the gate instead.
    """
    assert issubclass(_FakeTclError, tk.TclError)

    dead, alive = MagicMock(), MagicMock()
    dead.configure.side_effect = _FAKE_TK.TclError("bad window path name")
    # Must not raise: the group has to skip the dead copy and configure the
    # live one, exactly as it does on a real monitor going dark.
    _gatelock_widgetgroups.WidgetGroup([dead, alive]).config(fg="#ff0000")
    alive.configure.assert_called_once_with(fg="#ff0000")
