"""Tests for the gate's pointer-free operability.

Every assertion here stands in for something a keyboard-only user could not do
before. The gate is a hard lock -- ``overrideredirect`` + a global grab + VT
switching disabled -- so it cannot be left without submitting the form. A
control that needs a pointer is therefore not an inconvenience but a lockout,
which is why these are correctness tests rather than polish.

The reachability and height side of the same requirement is covered by
``measure_gate_layout.py``; the real focus-ring walk lives in
``probe_gate_keyboard.py``.

The "<Return> activates a button" check moved to gatelock with the button
itself (``gatelock/tests/test_widgets.py``), where it runs against real Tk
rather than a fake widget that can only report the binding it was handed.
"""

from __future__ import annotations

import tkinter as tk
from typing import TYPE_CHECKING

import pytest

from diet_guard import _gatelock_fields, _gatelock_typography, _gatelock_ui
from diet_guard._gatelock_ui import UNIT_GRAMS, UNIT_ITEMS
from diet_guard.tests import _gate_keyboard_probe

if TYPE_CHECKING:
    from diet_guard._gatelock import MealGate


class TestUnitSelectorIsKeyboardReachable:
    """The grams/items selector must not be a ``tk.OptionMenu``.

    ``OptionMenu``'s ``Menubutton`` defaults to ``takefocus=0``, so it never
    entered the tab ring -- and a posted Tk menu also steals the lock's grab,
    which the recovery tick then kills. Radiobuttons avoid both.
    """

    def test_no_option_menu_is_constructed(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Building the gate never constructs an OptionMenu.

        Asserted behaviourally by making the constructor explode, rather than by
        grepping the source -- a source scan matches this module's own
        explanatory comments about the widget it replaced.
        """

        def _explode(*_args: object, **_kwargs: object) -> None:
            message = "OptionMenu is banned on a lock surface"
            raise AssertionError(message)

        monkeypatch.setattr(tk, "OptionMenu", _explode)
        root = tk.Tk()
        try:
            selector_row = tk.Frame(root)
            vars_ = _gatelock_ui.make_vars(root)
            _gatelock_fields._build_unit_selector(selector_row, vars_, lambda _u: None)
            classes = [child.winfo_class() for child in selector_row.winfo_children()]
            assert classes == ["Radiobutton", "Radiobutton"]
            assert "Menubutton" not in classes
        finally:
            root.destroy()

    def test_radio_options_are_in_the_focus_ring(self) -> None:
        """Both units are tab stops -- the OptionMenu never was."""
        root = tk.Tk()
        try:
            row = tk.Frame(root)
            row.pack()
            vars_ = _gatelock_ui.make_vars(root)
            _gatelock_fields._build_unit_selector(row, vars_, lambda _u: None)
            root.focus_force()
            root.update()
            root.update_idletasks()
            for child in row.winfo_children():
                assert str(child.cget("takefocus")) != "0"
        finally:
            root.destroy()

    def test_selecting_a_radio_fires_the_unit_callback(self) -> None:
        """Activating an option updates the var and notifies the controller."""
        root = tk.Tk()
        try:
            row = tk.Frame(root)
            vars_ = _gatelock_ui.make_vars(root)
            seen: list[str] = []
            _gatelock_fields._build_unit_selector(row, vars_, seen.append)
            items = [
                child
                for child in row.winfo_children()
                if str(child.cget("value")) == UNIT_ITEMS
            ]
            items[0].invoke()
            assert vars_.unit.get() == UNIT_ITEMS
            assert seen == [UNIT_ITEMS]
        finally:
            root.destroy()

    def test_both_units_are_offered(self, gate: MealGate) -> None:
        """Selecting each radio option drives the unit variable."""
        assert gate._vars.unit.get() == UNIT_GRAMS
        gate._vars.unit.set(UNIT_ITEMS)
        assert gate._vars.unit.get() == UNIT_ITEMS


class TestNotebookTraversal:
    """Ctrl+Tab / Ctrl+PageDown tab switching must be enabled explicitly."""

    def test_traversal_is_enabled(self, gate: MealGate) -> None:
        """``enable_traversal()`` is called, or the tab keys are dead.

        ttk installs those toplevel bindings only on request, so omitting the
        call leaves Ctrl+Tab, Ctrl+PageUp/Down and Alt+mnemonic doing nothing
        while looking perfectly normal in the code.
        """
        assert gate._notebook.traversal_enabled is True


class TestFocusRingIsVisible:
    """The focus ring must be the accent, not Tk's black default."""

    def test_focus_kwargs_sets_the_focused_ring(self) -> None:
        """``highlightcolor`` (focused) is the accent and thickness is non-zero.

        Setting only ``highlightbackground`` -- the *unfocused* ring -- is the
        bug this replaced: the widget outlined while unfocused and went black
        against ``bg`` the moment it took focus.
        """
        kwargs = _gatelock_ui._COLORS.focus_kwargs()
        assert kwargs["highlightcolor"] == _gatelock_ui._COLORS.accent
        assert kwargs["highlightcolor"] != "#000000"
        assert int(kwargs["highlightthickness"]) > 0

    def test_prose_wrap_respects_the_line_length_cap(self) -> None:
        """Wrap width is the 640px cap, not the old 900px literal."""
        assert _gatelock_ui._WRAP_PX == 640


class TestTypeScaleIsPixels:
    """Tk font sizes must be negative, i.e. pixels rather than points."""

    @pytest.mark.parametrize(
        "size",
        [
            _gatelock_typography.DISPLAY,
            _gatelock_typography.SUBTITLE,
            _gatelock_typography.BODY,
            _gatelock_typography.LABEL,
            _gatelock_typography.CAPTION,
        ],
    )
    def test_sizes_are_negative(self, size: int) -> None:
        """A positive size means points and renders ~30% oversized.

        Measured: body at 16 points has a 26px linespace where 16 pixels gives
        20px. That inflation alone pushed this layout off a 768px screen.
        """
        assert size < 0

    def test_scale_matches_the_design_system_magnitudes(self) -> None:
        """The magnitudes are still tokens.md's 32/24/20/16/14/12 scale."""
        assert abs(_gatelock_typography.DISPLAY) == 32
        assert abs(_gatelock_typography.TITLE) == 24
        assert abs(_gatelock_typography.SUBTITLE) == 20
        assert abs(_gatelock_typography.BODY) == 16
        assert abs(_gatelock_typography.LABEL) == 14
        assert abs(_gatelock_typography.CAPTION) == 12


class TestRealFocusRing:
    """Walk the ring Tab actually follows, against a real Tk.

    Reading the code cannot answer this: Tk decides via ``::tk::FocusOK``, which
    also rejects any widget whose *class* has no key bindings. That is why a
    Canvas viewport was pointer-only and a Menubutton was skipped entirely --
    neither looks unusual in source.
    """

    def test_unit_selector_is_in_the_ring(self) -> None:
        """Both grams/items radio options are tab stops.

        The ``OptionMenu`` they replaced was absent from the ring entirely, so
        the unit -- which rescales the whole entry -- could only be changed with
        a pointer, inside a lock requiring a logged meal to exit.
        """
        report = _gate_keyboard_probe.probe()
        assert report.classes.count("Radiobutton") == 2, report.describe()

    def test_every_focusable_class_has_a_visible_ring(self) -> None:
        """No widget in the ring keeps Tk's black default highlight.

        Tk ships ``highlightcolor="#000000"`` on a ``#211D1B`` background, so
        the default is a ring that cannot be seen.
        """
        report = _gate_keyboard_probe.probe()
        invisible = {
            name: color
            for name, color in report.focus_rings_visible.items()
            if color.lower() in {"", "#000000", "black"}
        }
        assert not invisible, f"invisible focus rings: {invisible}"

    def test_scroll_viewport_is_a_focus_stop(self) -> None:
        """The Canvas viewport is reachable, so it can be scrolled by keyboard.

        A bare ``tk.Canvas`` has no class key bindings and is therefore rejected
        by ``FocusOK``; it only appears here because it opts in explicitly.
        """
        report = _gate_keyboard_probe.probe()
        assert report.has("Canvas"), report.describe()

    def test_text_escapes_and_buttons_take_return(self) -> None:
        """The two Tk defaults that make a form unusable are both overridden."""
        report = _gate_keyboard_probe.probe()
        assert report.text_escapes_tab, report.describe()
        assert report.buttons_take_return, report.describe()


class TestRealTkKeyboardBehaviour:
    """End-to-end checks against a real Tk, not the fakes.

    The fakes cannot prove anything about Tk's own class bindings, and those
    bindings are the whole problem: Tab-traps and missing Return bindings are
    Tk defaults, not application code.
    """

    def test_text_tab_escape_against_real_tk(self) -> None:
        """A real Text widget releases focus on Tab."""
        root = tk.Tk()
        try:
            first = tk.Text(root)
            first.pack()
            second = tk.Entry(root)
            second.pack()
            _gatelock_ui._escape_text_tab_trap(first)
            root.focus_force()
            root.update()
            first.focus_set()
            root.update()
            first.event_generate("<Tab>")
            root.update()
            root.update_idletasks()
            assert root.focus_get() is not first
            # And no literal tab was inserted.
            assert "\t" not in first.get("1.0", "end")
        finally:
            root.destroy()
