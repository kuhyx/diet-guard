"""Tests for the ``kuchnia`` subcommand and its dispatch wiring.

Split from ``test_kuchnia_import.py`` for the repo's 250-line cap; the banking
and logging behaviour those exercise lives there.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from diet_guard import _cli, _cli_kuchnia
from diet_guard._kuchnia_parse import Dish
from diet_guard._state_today import today_entries


def _dish(name: str = "Kaszotto", kcal: float = 391.0, priority: int = 1) -> Dish:
    return Dish(
        name=name,
        kcal=kcal,
        protein_g=32.5,
        carbs_g=35.6,
        fat_g=13.0,
        grams=318.0,
        priority=priority,
        slot_label="Kolacja",
    )


class TestCli:
    def _run(self, lines: list[str], **kwargs: bool) -> int:
        answers = iter(["y"])
        return _cli_kuchnia.cmd_kuchnia(
            lines.append,
            lambda _prompt: next(answers, "n"),
            log=kwargs.get("log", False),
            yes=kwargs.get("yes", False),
        )

    def test_dry_run_banks_but_does_not_log(self) -> None:
        lines: list[str] = []
        with patch.object(
            _cli_kuchnia, "refresh_delivery", return_value=([_dish()], None)
        ):
            assert self._run(lines) == 0
        assert today_entries() == []
        assert any("not logged" in line for line in lines)

    def test_reports_the_total(self) -> None:
        lines: list[str] = []
        dishes = [_dish("A", kcal=400.0), _dish("B", kcal=600.0, priority=2)]
        with patch.object(
            _cli_kuchnia, "refresh_delivery", return_value=(dishes, None)
        ):
            self._run(lines)
        assert any("total: 1000 kcal" in line for line in lines)

    def test_an_outage_exits_nonzero_without_touching_the_log(self) -> None:
        lines: list[str] = []
        with patch.object(
            _cli_kuchnia, "refresh_delivery", return_value=([], "panel down")
        ):
            assert self._run(lines) == 1
        assert today_entries() == []
        assert any("panel down" in line for line in lines)

    def test_no_delivery_today_is_a_clean_exit(self) -> None:
        lines: list[str] = []
        with patch.object(_cli_kuchnia, "refresh_delivery", return_value=([], None)):
            assert self._run(lines) == 0
        assert any("no catering delivery" in line for line in lines)

    def test_log_asks_first(self) -> None:
        lines: list[str] = []
        with (
            patch.object(
                _cli_kuchnia, "refresh_delivery", return_value=([_dish()], None)
            ),
            patch.object(_cli_kuchnia, "log_dishes", return_value=["A"]) as logger,
        ):
            self._run(lines, log=True)
        assert logger.call_count == 1

    def test_declining_the_prompt_logs_nothing(self) -> None:
        lines: list[str] = []
        with (
            patch.object(
                _cli_kuchnia, "refresh_delivery", return_value=([_dish()], None)
            ),
            patch.object(_cli_kuchnia, "log_dishes") as logger,
        ):
            _cli_kuchnia.cmd_kuchnia(
                lines.append,
                lambda _prompt: "n",
                log=True,
                yes=False,
            )
        assert logger.call_count == 0
        assert any("nothing logged" in line for line in lines)

    def test_yes_skips_the_prompt(self) -> None:
        lines: list[str] = []
        asked: list[str] = []
        with (
            patch.object(
                _cli_kuchnia, "refresh_delivery", return_value=([_dish()], None)
            ),
            patch.object(_cli_kuchnia, "log_dishes", return_value=["A"]),
        ):

            def _record(prompt: str) -> str:
                asked.append(prompt)
                return "y"

            _cli_kuchnia.cmd_kuchnia(lines.append, _record, log=True, yes=True)
        assert asked == []

    def test_already_logged_says_so(self) -> None:
        lines: list[str] = []
        with (
            patch.object(
                _cli_kuchnia, "refresh_delivery", return_value=([_dish()], None)
            ),
            patch.object(_cli_kuchnia, "log_dishes", return_value=[]),
        ):
            self._run(lines, log=True, yes=True)
        assert any("already logged" in line for line in lines)


class TestDispatch:
    """The subcommand must actually be reachable through ``python -m``."""

    def test_the_subcommand_is_wired_into_main(self) -> None:
        with patch.object(
            _cli_kuchnia,
            "refresh_delivery",
            return_value=([_dish()], None),
        ):
            assert _cli.main(["kuchnia"]) == 0

    def test_the_log_flags_reach_the_handler(self) -> None:
        with (
            patch.object(
                _cli_kuchnia,
                "refresh_delivery",
                return_value=([_dish()], None),
            ),
            patch.object(_cli_kuchnia, "log_dishes", return_value=["A"]) as logger,
        ):
            assert _cli.main(["kuchnia", "--log", "--yes"]) == 0
        assert logger.call_count == 1


def test_unknown_lazy_attribute_raises() -> None:
    # The name lives in a variable so ruff cannot fold the lookup into a
    # bare attribute access and then flag it as a useless expression.
    missing = "not_a_real_helper"
    with pytest.raises(AttributeError, match="no attribute"):
        getattr(_cli_kuchnia, missing)
