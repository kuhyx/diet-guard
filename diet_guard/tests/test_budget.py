"""Tests for _budget.py — the hidden, tamper-hardened daily budget."""

from __future__ import annotations

import base64
import json
from pathlib import Path
from typing import TYPE_CHECKING, cast
from unittest.mock import patch

import pytest

from python_pkg.diet_guard import _budget
from python_pkg.diet_guard._budget import (
    Biometrics,
    BudgetLockedError,
    BudgetNotInitializedError,
    BudgetSealBrokenError,
    budget_weight,
    compute_target_budget,
    daily_budget,
    is_initialized,
    lock_command,
    mifflin_st_jeor_bmr,
    protein_target_g,
    seal_budget,
    unlock_command,
)

if TYPE_CHECKING:
    from collections.abc import Callable, Iterator

# A reusable, realistic body profile (the user's own stats).
_BIO = Biometrics(weight_kg=80.0, height_cm=169.0, age_years=26.0, is_male=True)


def _write_record(record: object) -> None:
    """Write an arbitrary object as the seal file (for tamper tests)."""
    _budget.BUDGET_FILE.write_text(json.dumps(record), encoding="utf-8")


def _budget_open_raises(exc: type[BaseException]) -> object:
    """Patch ``Path.open`` to raise ``exc`` ONLY for the sealed-budget file.

    ``Path`` instances use ``__slots__`` so ``patch.object(BUDGET_FILE, "open")``
    fails; and patching ``Path.open`` wholesale would also break the unrelated
    HMAC-key read inside ``compute_entry_hmac``.  Routing every other path to the
    real ``open`` keeps the failure surgically on the budget file.

    Args:
        exc: The exception type to raise when the budget file is opened.

    Returns:
        An unstarted ``patch`` context manager.
    """
    # Capture the real opener as a permissive callable so forwarding the
    # patched-through args (typed ``object`` here) is not rejected on arg types.
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
        """An absurd deficit cannot seal a starvation-level budget."""
        result = compute_target_budget(_BIO, activity_factor=1.0, deficit_kcal=5000)
        assert result == _budget._MIN_SANE_BUDGET


class TestExceptions:
    """Each budget error carries a fixed message."""

    def test_messages(self) -> None:
        """Constructors set a non-empty message with no arguments."""
        assert str(BudgetNotInitializedError())
        assert str(BudgetSealBrokenError())
        assert str(BudgetLockedError())


class TestSealAndRead:
    """Round-tripping the sealed budget."""

    def test_roundtrip(self) -> None:
        """A sealed value reads back exactly."""
        seal_budget(2000)
        assert daily_budget() == 2000

    def test_is_initialized(self) -> None:
        """is_initialized reflects whether the file exists."""
        assert not is_initialized()
        seal_budget(2000)
        assert is_initialized()

    def test_file_is_not_plaintext(self) -> None:
        """The number is base64-wrapped, not stored as a bare integer."""
        seal_budget(2345)
        raw = _budget.BUDGET_FILE.read_text(encoding="utf-8")
        assert "2345" not in raw

    def test_unsigned_accepted_when_no_key(self) -> None:
        """With no HMAC key, an unsigned seal is written and accepted."""
        with patch.object(_budget, "compute_entry_hmac", return_value=None):
            seal_budget(1800)
            record = json.loads(_budget.BUDGET_FILE.read_text(encoding="utf-8"))
            assert "hmac" not in record
            assert daily_budget() == 1800

    def test_locked_file_raises(self) -> None:
        """An unwritable (immutable) file surfaces as BudgetLockedError."""
        with _budget_open_raises(PermissionError), pytest.raises(BudgetLockedError):
            seal_budget(2000)


class TestReadFailures:
    """daily_budget's defensive paths."""

    def test_missing_file(self) -> None:
        """No file yet -> not initialized."""
        with pytest.raises(BudgetNotInitializedError):
            daily_budget()

    def test_unreadable_file(self) -> None:
        """An OSError while reading surfaces as a broken seal."""
        seal_budget(2000)
        with _budget_open_raises(OSError), pytest.raises(BudgetSealBrokenError):
            daily_budget()

    def test_invalid_json(self) -> None:
        """Garbage content -> broken seal."""
        _budget.BUDGET_FILE.write_text("not json", encoding="utf-8")
        with pytest.raises(BudgetSealBrokenError):
            daily_budget()

    def test_record_not_dict(self) -> None:
        """A non-object top level -> broken seal."""
        _write_record([1, 2, 3])
        with pytest.raises(BudgetSealBrokenError):
            daily_budget()

    def test_data_not_string(self) -> None:
        """A non-string data field -> broken seal."""
        _write_record({"data": 123})
        with pytest.raises(BudgetSealBrokenError):
            daily_budget()

    def test_bad_base64(self) -> None:
        """Undecodable base64 -> broken seal."""
        _write_record({"data": "!!!not base64!!!"})
        with pytest.raises(BudgetSealBrokenError):
            daily_budget()

    def test_inner_not_dict(self) -> None:
        """base64 that decodes to a non-object -> broken seal."""
        inner = base64.b64encode(b"[1,2,3]").decode("ascii")
        _write_record({"data": inner})
        with pytest.raises(BudgetSealBrokenError):
            daily_budget()

    def test_tampered_signature(self) -> None:
        """A forged value with a bad signature is rejected."""
        forged = base64.b64encode(b'{"b":9999,"v":1}').decode("ascii")
        _write_record({"data": forged, "hmac": "deadbeef"})
        with pytest.raises(BudgetSealBrokenError):
            daily_budget()

    def test_unsigned_rejected_when_key_available(self) -> None:
        """A stripped signature on a keyed system means tampering."""
        valid = base64.b64encode(b'{"b":2000,"v":1}').decode("ascii")
        _write_record({"data": valid})  # no hmac, but a key exists
        with pytest.raises(BudgetSealBrokenError):
            daily_budget()

    def test_signature_present_but_key_missing(self) -> None:
        """A signed seal cannot be verified once the key is gone."""
        seal_budget(2000)
        with (
            patch.object(
                _budget,
                "compute_entry_hmac",
                return_value=None,
            ),
            pytest.raises(BudgetSealBrokenError),
        ):
            daily_budget()

    def test_non_integer_value(self) -> None:
        """A non-integer budget (here a bool) is rejected."""
        # Sign a record whose inner "b" is a bool, so the signature is valid but
        # the value type is wrong.
        inner = {"v": 1, "b": True}
        blob = json.dumps(inner, sort_keys=True, separators=(",", ":")).encode()
        record = {
            "data": base64.b64encode(blob).decode("ascii"),
            "hmac": _budget.compute_entry_hmac(inner),
        }
        _write_record(record)
        with pytest.raises(BudgetSealBrokenError):
            daily_budget()


class TestWeightAndProtein:
    """The v2 stored weight and the protein target derived from it."""

    def test_seal_with_weight_roundtrips(self) -> None:
        """A weight sealed alongside the budget reads back."""
        seal_budget(2200, weight_kg=80.0)
        assert daily_budget() == 2200
        assert budget_weight() == pytest.approx(80.0)

    def test_protein_target_from_weight(self) -> None:
        """The protein target is weight x the per-kg constant."""
        seal_budget(2200, weight_kg=80.0)
        expected = round(80.0 * _budget.PROTEIN_G_PER_KG, 1)
        assert protein_target_g() == pytest.approx(expected)

    def test_v1_seal_has_no_weight(self) -> None:
        """A budget sealed without a weight exposes no weight or protein target."""
        seal_budget(2000)
        assert budget_weight() is None
        assert protein_target_g() is None

    def test_protein_target_none_when_uninitialized(self) -> None:
        """With nothing sealed, the protein target is quietly None, not an error."""
        assert protein_target_g() is None

    def test_budget_weight_rejects_non_numeric(self) -> None:
        """A validly-signed but non-numeric weight yields None, not a crash."""
        inner = {"v": 2, "b": 2000, "w": True}
        blob = json.dumps(inner, sort_keys=True, separators=(",", ":")).encode()
        record = {
            "data": base64.b64encode(blob).decode("ascii"),
            "hmac": _budget.compute_entry_hmac(inner),
        }
        _write_record(record)
        assert budget_weight() is None


class TestCommands:
    """The chattr helper strings."""

    def test_lock_unlock_commands(self) -> None:
        """Both reference the budget path with the right chattr flag."""
        assert lock_command().startswith("sudo chattr +i ")
        assert unlock_command().startswith("sudo chattr -i ")
        assert str(_budget.BUDGET_FILE) in lock_command()
