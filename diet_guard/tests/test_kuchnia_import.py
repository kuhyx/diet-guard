"""Tests for banking catering dishes, logging them, and the CLI around both.

The bank idempotency test is the one that earns its keep. ``add_manual_entry``
restamps ``t`` unconditionally and the sync merge derives each record's clock
from that stamp, so a refresh that re-banks unchanged dishes republishes the
*entire* curated bank to every peer. Asserting "the entry exists" passes while
that happens, so these assert on **call count** instead.
"""

from __future__ import annotations

import datetime
from unittest.mock import patch

from diet_guard import _kuchnia_config, _kuchnia_import
from diet_guard._foodbank_manual import read_manual_bank
from diet_guard._kuchnia_errors import KuchniaError
from diet_guard._kuchnia_import import bank_dishes, dish_to_record, refresh_delivery
from diet_guard._kuchnia_log import log_dishes
from diet_guard._kuchnia_parse import Dish
from diet_guard._kuchnia_spread import SlottedDish
from diet_guard._state_today import today_entries, today_total_kcal

DAY = datetime.date(2026, 8, 22)


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


class TestBankDishes:
    def test_banks_a_dish_with_its_portion_macros(self) -> None:
        bank_dishes([_dish()])
        bank = read_manual_bank()
        record = bank["kaszotto"]
        assert record["kcal"] == 391.0
        assert record["grams"] == 318.0
        # count is 0: the bank's count ranks foods by how often they were
        # *eaten*, and a delivered dish has not been eaten yet.
        assert record["count"] == 0

    def test_polish_names_normalise_without_mangling(self) -> None:
        bank_dishes([_dish(name="Kaszotto Grzybowe Z Kurczakiem")])
        bank = read_manual_bank()
        (key,) = bank
        assert key == "kaszotto grzybowe z kurczakiem"
        assert bank[key]["desc"] == "Kaszotto Grzybowe Z Kurczakiem"

    def test_a_re_import_writes_nothing(self) -> None:
        dishes = [_dish("A"), _dish("B")]
        assert bank_dishes(dishes) == 2
        with patch(
            "diet_guard._kuchnia_import.add_manual_entry",
        ) as add:
            assert bank_dishes(dishes) == 0
        # Call count, not entry existence: the existence assertion passes even
        # when every record is needlessly restamped and resynced.
        assert add.call_count == 0

    def test_a_changed_dish_is_rewritten(self) -> None:
        bank_dishes([_dish("A", kcal=400.0)])
        with patch(
            "diet_guard._kuchnia_import.add_manual_entry",
        ) as add:
            assert bank_dishes([_dish("A", kcal=450.0)]) == 1
        assert add.call_count == 1

    def test_callers_never_stamp_the_edit_time(self) -> None:
        # ``t`` is set inside add_manual_entry; a caller-supplied one would
        # skew the last-writer-wins merge.
        assert "t" not in dish_to_record(_dish())

    def test_banking_nothing_is_not_an_error(self) -> None:
        assert bank_dishes([]) == 0


class TestRefreshDelivery:
    def test_returns_dishes_and_banks_them(self) -> None:
        dishes = [_dish()]
        with (
            patch.object(_kuchnia_import, "PanelSession"),
            patch.object(_kuchnia_import, "fetch_dishes", return_value=dishes),
        ):
            got, reason = refresh_delivery(DAY)
        assert reason is None
        assert got == dishes
        assert read_manual_bank()

    def test_an_outage_is_a_reason_not_an_exception(self) -> None:
        # Fail-closed: no caller may be broken by the catering being down.
        with patch.object(
            _kuchnia_import,
            "PanelSession",
            side_effect=KuchniaError("panel down"),
        ):
            got, reason = refresh_delivery(DAY)
        assert got == []
        assert reason == "panel down"

    def test_a_failed_fetch_banks_nothing(self) -> None:
        with patch.object(
            _kuchnia_import,
            "PanelSession",
            side_effect=KuchniaError("nope"),
        ):
            refresh_delivery(DAY)
        assert read_manual_bank() == {}


class TestRefreshOnce:
    """The guard that makes the automatic triggers affordable."""

    def test_the_first_call_of_the_day_fetches(self) -> None:
        with patch.object(
            _kuchnia_import,
            "refresh_delivery",
            return_value=([_dish()], None),
        ) as refresh:
            dishes, reason = _kuchnia_import.refresh_delivery_once(DAY)
        assert reason is None
        assert len(dishes) == 1
        assert refresh.call_count == 1

    def test_the_second_call_does_not_touch_the_network(self) -> None:
        # The gate and the after-log hook both fire many times a day; each
        # unguarded refresh is a login plus a three-request walk.
        with patch.object(
            _kuchnia_import,
            "refresh_delivery",
            return_value=([_dish()], None),
        ) as refresh:
            _kuchnia_import.refresh_delivery_once(DAY)
            dishes, reason = _kuchnia_import.refresh_delivery_once(DAY)
        assert refresh.call_count == 1
        assert (dishes, reason) == ([], None), "nothing new is not an error"

    def test_a_new_day_fetches_again(self) -> None:
        with patch.object(
            _kuchnia_import,
            "refresh_delivery",
            return_value=([_dish()], None),
        ) as refresh:
            _kuchnia_import.refresh_delivery_once(DAY)
            _kuchnia_import.refresh_delivery_once(DAY + datetime.timedelta(days=1))
        assert refresh.call_count == 2

    def test_an_outage_does_not_suppress_the_retry(self) -> None:
        with patch.object(
            _kuchnia_import,
            "refresh_delivery",
            return_value=([], "panel down"),
        ) as refresh:
            _kuchnia_import.refresh_delivery_once(DAY)
            _kuchnia_import.refresh_delivery_once(DAY)
        assert refresh.call_count == 2, "a failed day must be retried"

    def test_an_unreadable_marker_just_means_fetch_again(self) -> None:
        marker = _kuchnia_config.KUCHNIA_LAST_IMPORT_FILE
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.mkdir()  # a directory where a file belongs
        with patch.object(
            _kuchnia_import,
            "refresh_delivery",
            return_value=([_dish()], None),
        ) as refresh:
            _kuchnia_import.refresh_delivery_once(DAY)
        assert refresh.call_count == 1

    def test_the_marker_never_reaches_real_state(self) -> None:
        assert ".config/diet_guard" not in str(
            _kuchnia_config.KUCHNIA_LAST_IMPORT_FILE,
        )


class TestLogDishes:
    def test_logs_each_dish_into_its_slot(self) -> None:
        chosen = [
            SlottedDish(dish=_dish("A", kcal=100.0), slot=8),
            SlottedDish(dish=_dish("B", kcal=200.0), slot=12),
        ]
        assert log_dishes(chosen) == ["A", "B"]
        entries = today_entries()
        assert [entry["slot"] for entry in entries] == [8, 12]
        assert today_total_kcal() == 300.0

    def test_records_the_provenance(self) -> None:
        log_dishes([SlottedDish(dish=_dish("A"), slot=8)])
        (entry,) = today_entries()
        assert entry["source"] == "kuchnia wikinga"

    def test_a_second_run_logs_nothing(self) -> None:
        chosen = [SlottedDish(dish=_dish("A"), slot=8)]
        log_dishes(chosen)
        assert log_dishes(chosen) == []
        assert len(today_entries()) == 1

    def test_the_same_dish_in_a_different_slot_is_a_separate_meal(self) -> None:
        log_dishes([SlottedDish(dish=_dish("A"), slot=8)])
        assert log_dishes([SlottedDish(dish=_dish("A"), slot=12)]) == ["A"]
        assert len(today_entries()) == 2

    def test_duplicates_within_one_batch_land_once(self) -> None:
        # today_entries() is read once, before the loop; without reflecting the
        # writes locally both copies would be logged.
        chosen = [
            SlottedDish(dish=_dish("A"), slot=8),
            SlottedDish(dish=_dish("A"), slot=8),
        ]
        assert log_dishes(chosen) == ["A"]

    def test_matching_ignores_case_and_padding(self) -> None:
        log_dishes([SlottedDish(dish=_dish("Kaszotto"), slot=8)])
        assert log_dishes([SlottedDish(dish=_dish("  kaszotto  "), slot=8)]) == []

    def test_logging_nothing_is_not_an_error(self) -> None:
        assert log_dishes([]) == []
