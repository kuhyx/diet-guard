"""Tests for _slot_wire.py — a log entry's slot fields and clock parsing.

The cross-language cases live in the shared fixture
(``test_meal_schedule_vectors.py``); these pin the rule's intent readably,
plus ``parse_hhmm``, which is Python-only.
"""

from __future__ import annotations

import pytest

from diet_guard._slot_wire import entry_slot_minute, parse_hhmm, slot_fields


class TestSlotFields:
    """The writer half of the entry wire rule."""

    def test_whole_hour_is_byte_identical_to_the_old_format(self) -> None:
        """No ``slot_min`` key at all for 08:00."""
        assert slot_fields(480) == {"slot": 8}

    def test_off_hour_adds_the_minute(self) -> None:
        """07:15 keeps ``slot`` 7 for old readers and adds ``slot_min``."""
        assert slot_fields(435) == {"slot": 7, "slot_min": 435}

    @pytest.mark.parametrize("minute", [-1, 1440])
    def test_refuses_minutes_outside_the_day(self, minute: int) -> None:
        """A writer bug is refused rather than encoded."""
        with pytest.raises(ValueError, match=r"outside 0\.\.1439"):
            slot_fields(minute)


class TestEntrySlotMinute:
    """The reader half of the entry wire rule."""

    def test_legacy_hour_entry(self) -> None:
        """A pre-minute entry's ``slot`` is an hour."""
        assert entry_slot_minute({"slot": 8}) == 480

    def test_slot_min_wins(self) -> None:
        """``slot_min`` is authoritative, even when it is zero."""
        assert entry_slot_minute({"slot": 7, "slot_min": 435}) == 435
        assert entry_slot_minute({"slot": 5, "slot_min": 0}) == 0

    def test_bools_are_not_ints(self) -> None:
        """``True`` is rejected in both fields, as Dart's ``is int`` rejects it."""
        assert entry_slot_minute({"slot": 8, "slot_min": True}) == 480
        assert entry_slot_minute({"slot": True}) is None

    def test_no_slot(self) -> None:
        """An entry without an int slot reports none."""
        assert entry_slot_minute({}) is None
        assert entry_slot_minute({"slot": "8"}) is None


class TestParseHhmm:
    """User-typed clock times."""

    @pytest.mark.parametrize(
        ("text", "minute"),
        [
            ("7", 420),
            ("07", 420),
            ("7:15", 435),
            ("07:15", 435),
            (" 19:41 ", 1181),
            ("0", 0),
            ("23:59", 1439),
        ],
    )
    def test_accepted_forms(self, text: str, minute: int) -> None:
        """H, HH, H:MM and HH:MM, whitespace stripped."""
        assert parse_hhmm(text) == minute

    @pytest.mark.parametrize(
        "text",
        # chr(0x667) is ARABIC-INDIC DIGIT SEVEN, which ``\d`` and int() accept.
        ["", "7:5", "7:", ":15", "123", "07:15:00", "7.15", "x", chr(0x667)],
    )
    def test_rejects_malformed_text(self, text: str) -> None:
        """Anything else is a clear error, including non-ASCII digits."""
        with pytest.raises(ValueError, match="expected HH:MM"):
            parse_hhmm(text)

    @pytest.mark.parametrize("text", ["24", "24:00", "7:60", "99:99"])
    def test_rejects_out_of_range_values(self, text: str) -> None:
        """Hours must be 0-23 and minutes 0-59."""
        with pytest.raises(ValueError, match="hour must be 0-23"):
            parse_hhmm(text)
