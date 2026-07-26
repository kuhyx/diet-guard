"""Tests for _test_guard.py — the real-user-state write barrier.

Meta-tests: they assert that the guard protecting every *other* test is
itself working.  Deliberately exercised against the real protected paths,
because "does a write to the real path raise?" is the whole question -- the
guard raises before any I/O happens, so nothing is created.
"""

from __future__ import annotations

import pathlib
import sys
from unittest.mock import patch

import pytest

from diet_guard import _test_guard
from diet_guard._test_guard import RealUserStateWriteError

_REAL_TOKEN = pathlib.Path.home() / ".config" / "diet_guard" / "sync_token"
_REAL_LOG = pathlib.Path.home() / ".local" / "share" / "diet_guard" / "food_log.json"


class TestBlocksRealWrites:
    """The exact accident that destroyed the user's PAT must be impossible."""

    def test_write_text_to_the_real_token_raises(self) -> None:
        with pytest.raises(RealUserStateWriteError):
            _REAL_TOKEN.write_text("tok")

    def test_write_bytes_to_the_real_log_raises(self) -> None:
        with pytest.raises(RealUserStateWriteError):
            _REAL_LOG.write_bytes(b"{}")

    def test_opening_the_real_token_for_writing_raises(self) -> None:
        with pytest.raises(RealUserStateWriteError):
            _REAL_TOKEN.open("w")

    def test_appending_to_the_real_log_raises(self) -> None:
        with pytest.raises(RealUserStateWriteError):
            _REAL_LOG.open("a")

    def test_unlinking_real_state_raises(self) -> None:
        with pytest.raises(RealUserStateWriteError):
            _REAL_TOKEN.unlink()

    def test_renaming_real_state_raises(self) -> None:
        with pytest.raises(RealUserStateWriteError):
            _REAL_TOKEN.rename(_REAL_TOKEN.with_suffix(".moved"))

    def test_the_error_names_the_path_and_the_fix(self) -> None:
        with pytest.raises(RealUserStateWriteError) as caught:
            _REAL_TOKEN.write_text("tok")
        assert "sync_token" in str(caught.value)
        assert "tmp_path" in str(caught.value)


class TestAllowsEverythingElse:
    """The guard must not get in the way of legitimate test I/O."""

    def test_tmp_path_writes_are_untouched(self, tmp_path: pathlib.Path) -> None:
        target = tmp_path / "food_log.json"
        target.write_text("{}")
        assert target.read_text() == "{}"

    def test_reading_real_state_is_allowed(self) -> None:
        # Reads are safe and some checks legitimately want them; only writes
        # are barred. Absent file is fine -- the point is that it does not raise.
        assert _REAL_TOKEN.exists() in (True, False)

    def test_opening_real_state_for_reading_is_allowed(self) -> None:
        if _REAL_TOKEN.exists():
            with _REAL_TOKEN.open() as handle:
                handle.read()


class TestGuardInternals:
    """Edge cases in the path check and the install latch."""

    def test_an_unresolvable_path_is_not_treated_as_protected(self) -> None:
        assert not _test_guard._is_protected(pathlib.Path("\x00bad"))

    def test_an_unrelated_path_is_not_protected(self, tmp_path: pathlib.Path) -> None:
        assert not _test_guard._is_protected(tmp_path / "anything.json")

    def test_install_is_idempotent(self) -> None:
        """A second install must not wrap the already-wrapped methods again."""
        before = pathlib.Path.write_text
        _test_guard.install()
        assert pathlib.Path.write_text is before

    def test_install_is_a_no_op_outside_pytest(self) -> None:
        """Production imports diet_guard without pytest; the guard stays off."""
        before = pathlib.Path.write_text
        with patch.dict(sys.modules):
            del sys.modules["pytest"]
            _test_guard.install()
        assert pathlib.Path.write_text is before

    def test_guarding_an_already_guarded_method_is_a_no_op(self) -> None:
        """The per-method marker, not a module flag, is what makes it safe."""
        before = pathlib.Path.write_text
        _test_guard._guard("write_text", lambda *_a, **_k: True)
        assert pathlib.Path.write_text is before
