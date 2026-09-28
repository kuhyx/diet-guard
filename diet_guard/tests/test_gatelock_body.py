"""The gate's Body tab: its handlers, input parsing and weight graph.

Built on the in-memory Tk fakes (``fake_tk``), so no window ever opens.
"""

from __future__ import annotations

from datetime import date
from typing import TYPE_CHECKING
from unittest.mock import patch

import pytest

from diet_guard import _gatelock_body
from diet_guard._body_fat_store import body_fats
from diet_guard._body_prefs import saved_goal
from diet_guard._body_store import profile, set_profile, set_weight, weights
from diet_guard._budget import read_raw_record, write_budget
from diet_guard._gatelock_body import BodyTab
from diet_guard._gatelock_body_graph import (
    GraphBox,
    draw_weight_graph,
    graph_points,
    in_range,
    value_span,
)
from diet_guard._gatelock_body_input import parse_day, parse_float
from diet_guard.tests._gate_fixtures import fake_tk
from diet_guard.tests._tk_fakes import FakeCanvas, FakeNotebook

if TYPE_CHECKING:
    from collections.abc import Iterator


@pytest.fixture
def tab() -> Iterator[BodyTab]:
    with (
        fake_tk(),
        patch.object(_gatelock_body, "publish_after_log_detached") as publish,
    ):
        body = BodyTab(FakeNotebook())
        body.publish = publish  # the test can assert it
        yield body


def _person() -> None:
    set_profile(birth="2000-05-22", height_cm=169.0, sex="m")
    set_weight("2026-09-27", 72.6)


class TestInput:
    def test_parsing(self) -> None:
        assert parse_float(" 72,6 ") == 72.6
        assert parse_float("x") is None
        assert parse_day(" 2026-09-28") == "2026-09-28"
        assert parse_day("today") is None


class TestProfile:
    def test_rejects_then_saves(self, tab: BodyTab) -> None:
        tab.vars.profile.height.set("9")
        tab.save_profile()
        assert tab.vars.status.get().startswith("Profile needs")
        tab.vars.profile.birth.set("2000-05-22")
        tab.vars.profile.height.set("169")
        tab.vars.profile.sex.set("m")
        tab.save_profile()
        assert profile().complete
        assert tab.vars.status.get().startswith("Profile saved")

    def test_complete_profile_loads_into_the_inputs(self) -> None:
        _person()
        with fake_tk():
            body = BodyTab(FakeNotebook())
        assert body.vars.profile.height.get() == "169"
        assert body.vars.goal.answer.get().startswith("eat ")


class TestWeights:
    def test_save_reject_delete(self, tab: BodyTab) -> None:
        write_budget(2000, weight_kg=90.0)
        tab.vars.logs.weight.set("5")
        tab.save_weight()
        assert tab.vars.status.get().startswith("Weight needs")
        tab.vars.logs.weight.set("80")
        tab.vars.logs.weight_day.set("2026-09-10")
        tab.save_weight()
        assert weights() == {"2026-09-10": 80.0}
        assert (read_raw_record() or {})["w"] == 80.0
        tab.vars.logs.weight_day.set("nope")
        tab.delete_weight()
        assert tab.vars.status.get().startswith("Type the")
        tab.vars.logs.weight_day.set("2026-09-10")
        tab.delete_weight()
        assert weights() == {}

    def test_body_fat_save_reject_delete(self, tab: BodyTab) -> None:
        tab.vars.logs.body_fat.set("90")
        tab.save_body_fat()
        assert tab.vars.status.get().startswith("Body fat needs")
        tab.vars.logs.body_fat.set("17")
        tab.save_body_fat()
        assert body_fats() == {tab.vars.logs.fat_day.get(): 17.0}
        tab.vars.logs.fat_day.set("x")
        tab.delete_body_fat()
        assert tab.vars.status.get().startswith("Type the")
        tab.vars.logs.fat_day.set(next(iter(body_fats())))
        tab.delete_body_fat()
        assert body_fats() == {}


class TestGoalAndGraph:
    def test_goal_change_saves_and_reanswers(self, tab: BodyTab) -> None:
        _person()
        tab.vars.goal.weight_unit.set("lb")
        tab.vars.goal.amount.set("oops")
        tab.goal_changed()
        assert saved_goal().weight_unit == "lb"
        assert saved_goal().amount == 0.5  # unreadable amount kept
        assert tab.vars.goal.amount.get() == "0.5"
        assert tab.vars.goal.answer.get().startswith("eat ")

    def test_range_and_body_fat_graph(self, tab: BodyTab) -> None:
        _person()
        tab.vars.plan.days[0].set("2500")
        tab.vars.plan.target.set("")
        tab.set_range(None)
        tab.vars.logs.graph.set("fat")
        tab.refresh()
        assert "Mon" in tab.vars.blocks["plan"].get()


class TestGraph:
    def test_in_range_and_span(self) -> None:
        log = {"2026-01-01": 80.0, "2026-09-27": 72.0}
        assert in_range(log, date(2026, 9, 28), None) == log
        assert in_range(log, date(2026, 9, 28), 30) == {"2026-09-27": 72.0}
        low, high = value_span([72.0], (50.0, 71.0))
        assert low < 71.0 < high
        low, high = value_span([72.0], (40.0, 45.0))
        assert low > 45.0

    def test_single_point_is_centred(self) -> None:
        box = GraphBox(700, 300)
        ((x, _),) = graph_points({"2026-09-27": 72.0}, box, (71.0, 73.0))
        assert x == pytest.approx(box.x(0.5))

    def test_draws_band_line_and_labels_or_a_hint(self) -> None:
        canvas = FakeCanvas()
        box = GraphBox(700, 300)
        draw_weight_graph(canvas, {}, box, None)
        assert canvas.drawn[0][0] == "text"
        log = {"2026-09-20": 74.0, "2026-09-27": 72.0}
        draw_weight_graph(canvas, log, box, (52.8, 71.1))
        kinds = [kind for kind, _, _ in canvas.drawn]
        assert "rectangle" in kinds
        assert kinds.count("oval") == 2
        draw_weight_graph(canvas, log, box, (10.0, 20.0))  # band far off-axis
        assert "rectangle" not in [kind for kind, _, _ in canvas.drawn]
