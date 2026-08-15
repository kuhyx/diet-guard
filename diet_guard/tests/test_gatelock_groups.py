"""Per-output fan-out: the point of the gatelock v0.2.0 migration.

Every other test here runs against the single-output default, where "the gate
is on every monitor" and "the gate is on the primary and nowhere else" are
indistinguishable. These run on a two-monitor desk, so a loop that only ever
touched the first surface fails here and nowhere else.
"""

from __future__ import annotations

import tkinter as tk
from unittest.mock import MagicMock

import pytest

from diet_guard._gatelock_groups import (
    EntryGroup,
    ListboxGroup,
    TextGroup,
    WidgetGroup,
)


class TestGroupsInIsolation:
    """The group primitives, without a gate around them."""

    def test_config_reaches_a_dead_copy_without_raising(self) -> None:
        """A monitor that vanished mid-update must not break the others."""
        dead, alive = MagicMock(), MagicMock()
        dead.configure.side_effect = tk.TclError("bad window path name")

        WidgetGroup([dead, alive]).config(fg="#ff0000")

        alive.configure.assert_called_once_with(fg="#ff0000")

    def test_focus_skips_a_dead_copy(self) -> None:
        """Focus is singular: the first live copy takes it."""
        dead, alive = MagicMock(), MagicMock()
        dead.focus_set.side_effect = tk.TclError("gone")
        dead.focus_force.side_effect = tk.TclError("gone")
        group = WidgetGroup([dead, alive])

        group.focus_set()
        group.focus_force()

        alive.focus_set.assert_called_once_with()
        alive.focus_force.assert_called_once_with()

    def test_bind_reaches_every_copy_and_survives_a_dead_one(self) -> None:
        """Re-wiring after an output returns must not raise on a dead copy."""
        dead, alive = MagicMock(), MagicMock()
        dead.bind.side_effect = tk.TclError("gone")
        handler = MagicMock()

        WidgetGroup([dead, alive]).bind("<Return>", handler)

        # ``add=""`` is Tk's own spelling for "replace any existing binding",
        # which is what this gate needs: _wire_events runs once per surface
        # *and* again on rebuild, so an additive bind would stack a second
        # handler on every surviving widget and submit the meal twice.
        alive.bind.assert_called_once_with("<Return>", handler, add="")

    def test_first_on_an_empty_group_raises(self) -> None:
        """The gate always builds a copy before reading one.

        gatelock's ``first`` returns ``None`` for the zero-output case, which
        is right for a library. Here it is re-narrowed to the widget type so
        the specialized groups can read it without a None check, so the empty
        case has to be an explicit error rather than a ``None`` that would
        surface later as an ``AttributeError`` somewhere unrelated.
        """
        with pytest.raises(IndexError, match="empty"):
            _ = WidgetGroup([]).first

    def test_rebinding_replaces_rather_than_stacking(self) -> None:
        """``_wire_events`` runs again on rebuild; it must stay idempotent.

        gatelock's own ``WidgetGroup.bind`` defaults to *additive*, because its
        callers bind once and must not clobber someone else's handler. This
        gate is the other case: every re-wire would otherwise leave a second
        ``<Return>`` handler attached and log the meal twice.
        """
        widget = MagicMock()
        handler = MagicMock()
        group = WidgetGroup([widget])

        group.bind("<Return>", handler)
        group.bind("<Return>", handler)

        assert [call.kwargs["add"] for call in widget.bind.call_args_list] == ["", ""]

    def test_focus_when_every_copy_is_gone(self) -> None:
        """All surfaces destroyed: nothing to focus, and no exception."""
        dead = MagicMock()
        dead.focus_set.side_effect = tk.TclError("gone")
        dead.focus_force.side_effect = tk.TclError("gone")
        group = WidgetGroup([dead])

        group.focus_set()  # must not raise
        group.focus_force()

        assert dead.focus_set.called

    def test_entry_group_reads_and_writes_through_the_variable(self) -> None:
        """The widgets are never consulted, so copies cannot disagree."""
        var = MagicMock()
        var.get.return_value = "42"
        group = EntryGroup([MagicMock(), MagicMock()], var)

        group.insert(0, "42")
        value = group.get()
        group.delete(0, "end")

        assert value == "42"
        var.set.assert_any_call("42")
        var.set.assert_called_with("")

    def test_text_group_falls_back_to_the_primary_when_all_blank(self) -> None:
        """An untouched form still yields a string for validation to reject."""
        first, second = MagicMock(), MagicMock()
        first.get.return_value = ""
        second.get.return_value = "   "

        assert TextGroup([first, second]).get("1.0", "end") == ""

    def test_text_group_skips_a_dead_copy(self) -> None:
        """A destroyed monitor's box is stepped over, not fatal."""
        dead, typed = MagicMock(), MagicMock()
        dead.get.side_effect = tk.TclError("gone")
        typed.get.return_value = "porridge"

        assert TextGroup([dead, typed]).get("1.0", "end") == "porridge"

    def test_text_group_writes_survive_a_dead_copy(self) -> None:
        """delete/insert reach the live copy even if another has gone."""
        dead, alive = MagicMock(), MagicMock()
        dead.delete.side_effect = tk.TclError("gone")
        dead.insert.side_effect = tk.TclError("gone")
        group = TextGroup([dead, alive])

        group.delete("1.0", "end")
        group.insert("1.0", "eggs")

        alive.delete.assert_called_once_with("1.0", "end")
        alive.insert.assert_called_once_with("1.0", "eggs")

    def test_listbox_selection_comes_from_the_copy_clicked(self) -> None:
        """A mouse pick lands on one monitor; that is the one that counts."""
        unclicked, clicked = MagicMock(), MagicMock()
        unclicked.curselection.return_value = ()
        clicked.curselection.return_value = (3,)

        assert ListboxGroup([unclicked, clicked]).curselection() == (3,)

    def test_listbox_selection_empty_everywhere(self) -> None:
        """Nothing picked anywhere reads back as no selection."""
        first, second = MagicMock(), MagicMock()
        first.curselection.return_value = ()
        second.curselection.return_value = ()

        assert ListboxGroup([first, second]).curselection() == ()

    def test_listbox_selection_skips_a_dead_copy(self) -> None:
        """A destroyed copy does not block reading the live one."""
        dead, clicked = MagicMock(), MagicMock()
        dead.curselection.side_effect = tk.TclError("gone")
        clicked.curselection.return_value = (1,)

        assert ListboxGroup([dead, clicked]).curselection() == (1,)

    def test_listbox_writes_and_size_fan_out(self) -> None:
        """Rows are written to every copy; the count reads from the primary."""
        first, second = MagicMock(), MagicMock()
        first.size.return_value = 2
        group = ListboxGroup([first, second])

        group.delete(0, "end")
        group.insert("end", "a", "b")
        group.selection_set(1)
        group.selection_clear(0, "end")

        assert group.size() == 2
        second.insert.assert_called_once_with("end", "a", "b")
        second.selection_set.assert_called_once_with(1)
        second.selection_clear.assert_called_once_with(0, "end")

    def test_listbox_selection_helpers_survive_a_dead_copy(self) -> None:
        """A dead copy is stepped over by both selection helpers."""
        dead, alive = MagicMock(), MagicMock()
        dead.selection_set.side_effect = tk.TclError("gone")
        dead.selection_clear.side_effect = tk.TclError("gone")
        dead.delete.side_effect = tk.TclError("gone")
        dead.insert.side_effect = tk.TclError("gone")
        group = ListboxGroup([dead, alive])

        group.selection_set(0, 2)
        group.selection_clear(0)
        group.delete(0)
        group.insert(0, "x")

        alive.selection_set.assert_called_once_with(0, 2)
        alive.selection_clear.assert_called_once_with(0)

    def test_first_exposes_the_primary_copy(self) -> None:
        """Reads that cannot fan out use the primary monitor's widget."""
        first, second = MagicMock(), MagicMock()

        assert WidgetGroup([first, second]).first is first

    def test_iterating_yields_every_copy(self) -> None:
        """Callers that genuinely need each widget can have them."""
        first, second = MagicMock(), MagicMock()

        assert list(WidgetGroup([first, second])) == [first, second]

    def test_discarding_an_unknown_output_changes_nothing(self) -> None:
        """Tearing down an output that was never built is a no-op."""
        from diet_guard._gatelock_groups import GateWidgetsGroup

        group = GateWidgetsGroup(MagicMock())
        bundle = MagicMock()
        group.add(bundle, "DP-0")

        group.discard("HDMI-9")

        assert group.bundles == [bundle]
