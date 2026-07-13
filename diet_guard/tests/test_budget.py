"""Tests for _budget.py — the freely-editable, synced daily budget."""

from __future__ import annotations

import json
from pathlib import Path
from typing import TYPE_CHECKING, cast
from unittest.mock import patch

import pytest

from diet_guard import _budget
from diet_guard._budget import (
    Biometrics,
    BudgetFileCorruptError,
    BudgetNotInitializedError,
    budget_weight,
    compute_target_budget,
    daily_budget,
    is_initialized,
    mifflin_st_jeor_bmr,
    protein_target_g,
    write_budget,
)

if TYPE_CHECKING:
    from collections.abc import Callable, Iterator

# A reusable, realistic body profile (the user's own stats).
_BIO = Biometrics(weight_kg=80.0, height_cm=169.0, age_years=26.0, is_male=True)


def _write_record(record: object) -> None:
    """Write an arbitrary object as the budget file (for corruption tests)."""
    _budget.BUDGET_FILE.write_text(json.dumps(record), encoding="utf-8")


def _budget_open_raises(exc: type[BaseException]) -> object:
    """Patch ``Path.open`` to raise ``exc`` ONLY for the budget file.

    ``Path`` instances use ``__slots__`` so ``patch.object(BUDGET_FILE, "open")``
    fails; routing every other path to the real ``open`` keeps the failure
    surgically on the budget file.

    Args:
        exc: The exception type to raise when the budget file is opened.

    Returns:
        An unstarted ``patch`` context manager.
    """
    real_open = cast("Callable[..., Iterator[str]]", Path.open)

    def fake_open(self: Path, *args: object, **kwargs: object) -> Iterator[str]:
        if self == _budget.BUDGET_FILE:
            raise exc
        return real_open(self, *args, **kwargs)

    return patch("pathlib.Path.open", new=fake_open)


class TestMifflinStJeor:
    """The BMR formula's two sex branches."""

    def test_male_constant(self) -> None:
        """Male uses the +5 constant."""
        # 10*80 + 6.25*169 - 5*26 + 5 = 1731.25
        assert mifflin_st_jeor_bmr(_BIO) == pytest.approx(1731.25)

    def test_female_constant(self) -> None:
        """Female uses the -161 constant."""
        bio = Biometrics(weight_kg=80.0, height_cm=169.0, age_years=26.0, is_male=False)
        assert mifflin_st_jeor_bmr(bio) == pytest.approx(1731.25 - 166.0)


class TestComputeTargetBudget:
    """TDEE minus deficit, with a safety floor."""

    def test_typical_value(self) -> None:
        """A light-activity, modest-deficit target rounds as expected."""
        # 1731.25 * 1.375 - 180 = 2200.46... -> 2200
        result = compute_target_budget(_BIO, activity_factor=1.375, deficit_kcal=180)
        assert result == 2200

    def test_floored_to_minimum(self) -> None:
        """An absurd deficit cannot compute a starvation-level budget."""
        result = compute_target_budget(_BIO, activity_factor=1.0, deficit_kcal=5000)
        assert result == _budget._MIN_SANE_BUDGET


class TestExceptions:
    """Each budget error carries a fixed message."""

    def test_messages(self) -> None:
        """Constructors set a non-empty message with no arguments."""
        assert str(BudgetNotInitializedError())
        assert str(BudgetFileCorruptError())


class TestWriteAndRead:
    """Round-tripping the plainly-written budget."""

    def test_roundtrip(self) -> None:
        """A written value reads back exactly."""
        write_budget(2000)
        assert daily_budget() == 2000

    def test_is_initialized(self) -> None:
        """is_initialized reflects whether the file exists."""
        assert not is_initialized()
        write_budget(2000)
        assert is_initialized()

    def test_file_is_plain_json(self) -> None:
        """The number is stored in the open, readable format -- no wrapping."""
        write_budget(2345)
        record = json.loads(_budget.BUDGET_FILE.read_text(encoding="utf-8"))
        assert record["b"] == 2345

    def test_overwrite_replaces_the_value(self) -> None:
        """Writing again replaces the previous value, with no extra ritual."""
        write_budget(2000)
        write_budget(1800)
        assert daily_budget() == 1800


class TestReadFailures:
    """daily_budget's defensive paths."""

    def test_missing_file(self) -> None:
        """No file yet -> not initialized."""
        with pytest.raises(BudgetNotInitializedError):
            daily_budget()

    def test_unreadable_file(self) -> None:
        """An OSError while reading surfaces as a corrupt file."""
        write_budget(2000)
        with _budget_open_raises(OSError), pytest.raises(BudgetFileCorruptError):
            daily_budget()

    def test_invalid_json(self) -> None:
        """Garbage content -> corrupt file."""
        _budget.BUDGET_FILE.write_text("not json", encoding="utf-8")
        with pytest.raises(BudgetFileCorruptError):
            daily_budget()

    def test_record_not_dict(self) -> None:
        """A non-object top level -> corrupt file."""
        _write_record([1, 2, 3])
        with pytest.raises(BudgetFileCorruptError):
            daily_budget()

    def test_non_integer_value(self) -> None:
        """A non-integer budget (here a bool) is rejected."""
        _write_record({"v": 2, "b": True})
        with pytest.raises(BudgetFileCorruptError):
            daily_budget()


class TestWeightAndProtein:
    """The stored weight and the protein target derived from it."""

    def test_write_with_weight_roundtrips(self) -> None:
        """A weight written alongside the budget reads back."""
        write_budget(2200, weight_kg=80.0)
        assert daily_budget() == 2200
        assert budget_weight() == pytest.approx(80.0)

    def test_protein_target_from_weight(self) -> None:
        """The protein target is weight x the per-kg constant."""
        write_budget(2200, weight_kg=80.0)
        expected = round(80.0 * _budget.PROTEIN_G_PER_KG, 1)
        assert protein_target_g() == pytest.approx(expected)

    def test_no_weight_has_no_protein_target(self) -> None:
        """A budget written without a weight exposes no weight or target."""
        write_budget(2000)
        assert budget_weight() is None
        assert protein_target_g() is None

    def test_protein_target_none_when_uninitialized(self) -> None:
        """With no budget written, the protein target is quietly None."""
        assert protein_target_g() is None

    def test_budget_weight_rejects_non_numeric(self) -> None:
        """A non-numeric weight yields None, not a crash."""
        _write_record({"v": 2, "b": 2000, "w": True})
        assert budget_weight() is None


class TestRawRecord:
    """The sync-only raw-record read/write pair, which never raises."""

    def test_missing_file_returns_none(self) -> None:
        assert _budget.read_raw_record() is None

    def test_roundtrips_a_written_record(self) -> None:
        _budget.write_raw_record({"v": 2, "b": 1900, "t": "2026-01-01T00:00:00"})
        assert _budget.read_raw_record() == {
            "v": 2,
            "b": 1900,
            "t": "2026-01-01T00:00:00",
        }

    def test_unreadable_file_returns_none(self) -> None:
        write_budget(2000)
        with _budget_open_raises(OSError):
            assert _budget.read_raw_record() is None

    def test_invalid_json_returns_none(self) -> None:
        _budget.BUDGET_FILE.write_text("not json", encoding="utf-8")
        assert _budget.read_raw_record() is None

    def test_non_dict_record_returns_none(self) -> None:
        _write_record([1, 2, 3])
        assert _budget.read_raw_record() is None

    def test_write_budget_stamps_an_edit_timestamp(self) -> None:
        write_budget(2000)
        record = _budget.read_raw_record()
        assert record is not None
        assert record["t"]
