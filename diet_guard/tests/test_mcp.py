"""Tests for the MCP server tools in ``_mcp``.

Leaf helpers are patched at the ``_mcp`` module namespace (where they are
imported), keeping each tool's own logic under test while isolating the
already-tested state/resolution functions. No test touches the real food log,
budget seal, or shared HMAC key.
"""

from __future__ import annotations

from unittest.mock import patch

from diet_guard import _mcp
from diet_guard._budget import BudgetNotInitializedError
from diet_guard._estimator import Nutrition


def _nutrition(kcal: float = 250.0) -> Nutrition:
    return Nutrition(
        kcal=kcal,
        protein_g=10.0,
        carbs_g=20.0,
        fat_g=5.0,
        grams=150.0,
        source="manual",
    )


class TestGetStatus:
    def test_band_and_intake(self) -> None:
        with (
            patch.object(_mcp, "today_total_kcal", return_value=640.0),
            patch.object(_mcp, "today_total_macros", return_value=(30.0, 50.0, 12.0)),
            patch.object(_mcp, "consumption_band", return_value="on track"),
            patch.object(_mcp, "due_slots", return_value=(12,)),
            patch.object(_mcp, "logged_slots_today", return_value={8}),
            patch.object(_mcp, "current_slot", return_value=12),
            patch.object(_mcp, "now_local"),
            patch.object(_mcp, "slot_label", return_value="12:00"),
        ):
            out = _mcp.get_status()
        assert out["consumed_kcal"] == 640.0
        assert out["consumed_macros_g"] == {"protein": 30.0, "carbs": 50.0, "fat": 12.0}
        assert out["consumption_band"] == "on track"
        assert out["budget_initialized"] is True
        assert out["due_slots"] == ["12:00"]
        assert out["logged_slots"] == [8]
        assert out["current_slot"] == 12

    def test_no_budget_hides_band(self) -> None:
        with (
            patch.object(_mcp, "today_total_kcal", return_value=0.0),
            patch.object(_mcp, "today_total_macros", return_value=(0.0, 0.0, 0.0)),
            patch.object(
                _mcp,
                "consumption_band",
                side_effect=BudgetNotInitializedError(),
            ),
            patch.object(_mcp, "due_slots", return_value=()),
            patch.object(_mcp, "logged_slots_today", return_value=set()),
            patch.object(_mcp, "current_slot", return_value=None),
            patch.object(_mcp, "now_local"),
        ):
            out = _mcp.get_status()
        assert out["consumption_band"] is None
        assert out["budget_initialized"] is False
        assert out["due_slots"] == []
        assert out["logged_slots"] == []


class TestListToday:
    def test_projects_entries_and_drops_hmac(self) -> None:
        entries = [
            {
                "time": "2026-07-10T12:30:00",
                "desc": "big mac",
                "kcal": 550.0,
                "protein_g": 25.0,
                "carbs_g": 45.0,
                "fat_g": 30.0,
                "grams": 215.0,
                "source": "openfoodfacts: Big Mac",
                "slot": 12,
                "hmac": "deadbeef",
            },
        ]
        with patch.object(_mcp, "today_entries", return_value=entries):
            out = _mcp.list_today()
        assert out["count"] == 1
        view = out["entries"][0]
        assert view["desc"] == "big mac"
        assert view["kcal"] == 550.0
        assert view["slot"] == 12
        assert "hmac" not in view

    def test_empty(self) -> None:
        with patch.object(_mcp, "today_entries", return_value=[]):
            out = _mcp.list_today()
        assert out == {"count": 0, "entries": []}


class TestGetSlots:
    def test_lists_slots_and_current(self) -> None:
        with (
            patch.object(_mcp, "day_slots", return_value=(8, 12, 16, 20)),
            patch.object(_mcp, "current_slot", return_value=16),
            patch.object(_mcp, "now_local"),
            patch.object(_mcp, "slot_label", side_effect=lambda s: f"{s:02d}:00"),
        ):
            out = _mcp.get_slots()
        assert out["current_slot"] == 16
        assert out["day_slots"][0] == {"hour": 8, "label": "08:00"}
        assert len(out["day_slots"]) == 4


class TestLogMealGate:
    def test_unresolvable_returns_reason(self) -> None:
        with patch.object(_mcp, "resolve_nutrition", return_value=None):
            out = _mcp.log_meal("mystery stew")
        assert out["ok"] is False
        assert "could not resolve" in out["reason"]

    def test_preview_manual_macros_does_not_mutate(self) -> None:
        with (
            patch.object(
                _mcp, "resolve_nutrition", return_value=_nutrition()
            ) as resolve,
            patch.object(_mcp, "ManualMacros") as manual,
            patch.object(_mcp, "record_meal") as record,
        ):
            out = _mcp.log_meal(
                "protein shake",
                macros=_mcp.Macros(kcal=180.0, protein=30.0, carbs=5.0, fat=2.0),
                slot=12,
            )
        manual.assert_called_once_with(kcal=180.0, protein=30.0, carbs=5.0, fat=2.0)
        resolve.assert_called_once_with(
            "protein shake", grams=None, manual_macros=manual.return_value
        )
        record.assert_not_called()
        assert out["preview"] is True
        assert out["target_slot"] == 12
        assert out["resolved"]["kcal"] == 250.0
        assert out["confirm_required"] is True

    def test_preview_no_manual_defaults_slot_to_current(self) -> None:
        with (
            patch.object(_mcp, "resolve_nutrition", return_value=_nutrition()),
            patch.object(_mcp, "ManualMacros") as manual,
            patch.object(_mcp, "current_slot", return_value=8),
            patch.object(_mcp, "now_local"),
            patch.object(_mcp, "record_meal") as record,
        ):
            out = _mcp.log_meal("apple")
        manual.assert_not_called()
        record.assert_not_called()
        assert out["preview"] is True
        assert out["target_slot"] == 8

    def test_confirm_applies_signed(self) -> None:
        entry = {"desc": "apple", "hmac": "sig"}
        with (
            patch.object(_mcp, "resolve_nutrition", return_value=_nutrition()),
            patch.object(_mcp, "record_meal", return_value=entry) as record,
        ):
            out = _mcp.log_meal("apple", slot=8, confirm=True)
        record.assert_called_once()
        assert out["applied"] is True
        assert out["signed"] is True
        assert out["target_slot"] == 8

    def test_confirm_applies_unsigned(self) -> None:
        entry = {"desc": "apple"}
        with (
            patch.object(_mcp, "resolve_nutrition", return_value=_nutrition()),
            patch.object(_mcp, "record_meal", return_value=entry),
        ):
            out = _mcp.log_meal("apple", slot=8, confirm=True)
        assert out["applied"] is True
        assert out["signed"] is False

    def test_confirm_write_failure_returns_gracefully(self) -> None:
        with (
            patch.object(_mcp, "resolve_nutrition", return_value=_nutrition()),
            patch.object(_mcp, "record_meal", side_effect=OSError("disk full")),
        ):
            out = _mcp.log_meal("apple", slot=8, confirm=True)
        assert out["ok"] is False
        assert "could not write" in out["reason"]


def test_main_runs_stdio_server() -> None:
    with patch.object(_mcp.mcp, "run") as run:
        _mcp.main()
    run.assert_called_once_with()
