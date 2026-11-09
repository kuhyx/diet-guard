"""Guard: nothing the PC gate paints carries a word (kuhy's textgate rule).

Every Tk surface of the gate -- Log Meal, History and Body tabs, their status
lines, buttons, notebook tabs and canvas captions -- must show glyphs, numbers
and unit symbols only. Text the user wrote (typed entries, logged food names)
is content and stays; the fake ``Entry``/``Text``/``Listbox`` widgets that hold
it are not recorded at all.

The recorder hooks the fake widgets themselves, so it sees what the gate
*built* and what it *later set*: ``text=`` at construction, ``config(text=)``
afterwards, every value written into a variable some widget displays, the
values of an ``OptionMenu``, notebook tab titles and canvas ``create_text``.
It fails closed: a run that recorded too little (a module escaped the fake tk)
is red, and a canary proves one injected word turns the check red.
"""

from __future__ import annotations

from contextlib import contextmanager
import re
from typing import TYPE_CHECKING
from unittest.mock import patch

from diet_guard._budget import write_budget
from diet_guard._gatelock import MealGate
from diet_guard._state import log_meal
from diet_guard.tests._gate_fixtures import fake_tk
from diet_guard.tests._tk_fakes import FakeCanvas, FakeNotebook, FakeVar, FakeWidget
from diet_guard.tests.conftest import _nutrition

if TYPE_CHECKING:
    from collections.abc import Iterator

# Unit symbols next to a number, and the one method acronym kuhy kept (DOUBT
# rows in the rework's keep.md). Anything else of 2+ letters is a word.
UNITS = frozenset({"kcal", "kg", "lb", "st", "cm", "km", "min", "MET"})
# Food names logged by the scenario below: user content, shown on purpose.
CONTENT = frozenset({"apple"})
WORD = re.compile(r"[^\W\d_]{2,}")


def words_in(text: object) -> list[str]:
    """Every 2+ letter word in ``text`` that is neither a unit nor content."""
    return [w for w in WORD.findall(str(text)) if w not in UNITS | CONTENT]


class Recorder:
    """Collects every string the fake widgets would paint."""

    def __init__(self) -> None:
        self.widgets: list[FakeWidget] = []
        self.shown_vars: list[FakeVar] = []
        self.var_history: dict[int, list[str]] = {}
        self.tabs: list[str] = []
        self.canvas_text: list[str] = []
        self.menu_values: list[str] = []

    def texts(self) -> list[str]:
        """All painted strings, history included (a status shown once counts)."""
        out = [str(w.configured.get("text", "")) for w in self.widgets]
        for var in self.shown_vars:
            out.extend(self.var_history.get(id(var), [var.get()]))
        return [*out, *self.tabs, *self.canvas_text, *self.menu_values]

    def offenders(self) -> list[str]:
        """The painted strings that hold a word."""
        return sorted({t for t in self.texts() if words_in(t)})


@contextmanager
def recording() -> Iterator[Recorder]:
    """Hook the fake widgets so every painted string lands in a recorder."""
    rec = Recorder()
    widget_init, var_init, var_set = (
        FakeWidget.__init__,
        FakeVar.__init__,
        FakeVar.set,
    )
    tab_add, canvas_text = FakeNotebook.add, FakeCanvas.create_text

    def init(self: FakeWidget, *args: object, **kwargs: object) -> None:
        widget_init(self, *args, **kwargs)
        rec.widgets.append(self)
        shown = kwargs.get("textvariable")
        if isinstance(shown, FakeVar):
            rec.shown_vars.append(shown)
        if len(args) > 1 and isinstance(args[1], FakeVar):  # tk.OptionMenu
            rec.shown_vars.append(args[1])
            rec.menu_values.extend(str(v) for v in args[2:])

    def vinit(self: FakeVar, master: object = None, value: str = "") -> None:
        var_init(self, master, value)
        rec.var_history[id(self)] = [value]

    def vset(self: FakeVar, value: str) -> None:
        var_set(self, value)
        rec.var_history.setdefault(id(self), []).append(str(value))

    def add(self: FakeNotebook, child: object, *, text: str = "") -> None:
        tab_add(self, child, text=text)
        rec.tabs.append(text)

    def ctext(self: FakeCanvas, *args: object, **kwargs: object) -> int:
        rec.canvas_text.append(str(kwargs.get("text", "")))
        return canvas_text(self, *args, **kwargs)

    with (
        patch.object(FakeWidget, "__init__", init),
        patch.object(FakeVar, "__init__", vinit),
        patch.object(FakeVar, "set", vset),
        patch.object(FakeNotebook, "add", add),
        patch.object(FakeCanvas, "create_text", ctext),
    ):
        yield rec


def _drive(gate: MealGate) -> None:
    """Walk every user-reachable state that writes a status or caption."""
    gate._on_submit()  # nothing typed
    gate._set_desc("apple")
    gate._set_entry(gate._widgets.macros.protein, "x")
    gate._on_submit()  # macros not numbers
    gate._set_entry(gate._widgets.macros.protein, "")
    gate._on_submit()  # kcal missing
    for click in (gate._on_fill_all, gate._on_fetch_sync, gate._on_load_delivery):
        click()  # demo refusals
    write_budget(2000, weight_kg=80)
    log_meal("apple", _nutrition(95, 100), 8)
    gate._pending = [480, 720]
    gate._refresh_slot_header()
    gate._pending = []
    gate._refresh_slot_header()
    gate._refresh_dashboard()
    gate._refresh_projection()
    gate._refresh_calendar()
    gate._on_prev_month()
    gate._on_next_month()
    for value in ("x", "0", "1900"):
        gate._on_edit_or_save_budget()
        gate._cal_vars.budget.set(value)
        gate._on_edit_or_save_budget()
    gate._on_edit_or_save_schedule()
    gate._cal_vars.schedule.count.set("x")
    gate._on_edit_or_save_schedule()
    gate._cal_vars.schedule.count.set("4")
    gate._on_edit_or_save_schedule()


def _drive_body(gate: MealGate) -> None:
    """The Body tab's rejects, graph ranges and a saved reading."""
    tab = gate._body_tab
    tab.save_profile()
    tab.vars.logs.weight.set("5")
    tab.save_weight()
    tab.vars.logs.weight_day.set("nope")
    tab.delete_weight()
    tab.vars.logs.body_fat.set("90")
    tab.save_body_fat()
    tab.delete_body_fat()
    tab.set_range(30)
    tab.vars.profile.birth.set("2000-05-22")
    tab.vars.profile.height.set("169")
    tab.vars.profile.sex.set("m")
    tab.save_profile()
    tab.vars.logs.weight.set("72.5")
    tab.vars.logs.weight_day.set("2026-09-10")
    tab.save_weight()
    tab.set_range(None)
    tab.goal_changed()


def test_the_gate_paints_no_words() -> None:
    """Build and drive every tab; no painted string may hold a word."""
    with recording() as rec, fake_tk():
        built = MealGate(demo_mode=True)
        _drive(built)
        _drive_body(built)
    assert len(rec.tabs) >= 3, "the notebook tabs were not recorded"
    assert len(rec.widgets) > 40, "too few widgets recorded: a module escaped the fake"
    assert rec.canvas_text, "the Body graph drew nothing"
    offenders = rec.offenders()
    assert not offenders, "\n" + "\n".join(map(repr, offenders))


def test_the_guard_catches_an_injected_word() -> None:
    """Canary: the checker is red on a single word, and quiet on units/content."""
    with recording() as rec:
        FakeWidget(None, text="Save")
        FakeWidget(None, text="✓ 1900 kcal  apple")
    assert rec.offenders() == ["Save"]
    assert words_in("08:00 · 2/4  72.5 kg") == []
