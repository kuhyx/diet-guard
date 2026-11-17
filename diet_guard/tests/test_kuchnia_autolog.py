"""Catering auto-log: the PC logs the due slots' dishes before a lock opens.

kuhy overrode "delivered is not eaten" on 2026-11-17 ("LOG EVEN WITHOUT TAP").
Failure paths are fail-closed: nothing is logged and the lock opens as before.
"""

from __future__ import annotations

from datetime import date
import time
from unittest.mock import MagicMock, patch
import uuid

from crdt_sync import merge_logs

from diet_guard import _cli_gate, _kuchnia_autolog
from diet_guard._kuchnia_autolog import (
    FETCH_TIMEOUT_S,
    autolog_due_delivery,
    fetch_bounded,
    log_due_dishes,
)
from diet_guard._kuchnia_parse import Dish
from diet_guard._slot_wire import entry_slot_minute
from diet_guard._state_sync import find_entry, read_raw_log
from diet_guard.sync_merge import daylog_to_log, log_to_daylog

DAY = date(2026, 11, 17)
SLOTS = (480, 720, 960, 1200)


def _dish(name: str, priority: int, key: str) -> Dish:
    return Dish(name, 400.0, 25.0, 45.0, 12.0, 300.0, priority, "x", dish_key=key)


DISHES = [_dish("A", 1, "1001"), _dish("B", 2, "1002"), _dish("C", 3, "1003")]


def _id(key: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"kuchnia:2026-11-17:{key}"))


def _entries() -> list[dict[str, object]]:
    return [e for day in read_raw_log().values() for e in day]


def _run(due: tuple[int, ...]) -> list[str]:
    return log_due_dishes(DISHES, due, DAY, SLOTS)


class TestLogDueDishes:
    """Which dishes land, under which id."""

    def test_only_due_slots_are_logged(self) -> None:
        """Dishes of slots that are not due stay unlogged."""
        # 3 dishes on 4 slots: A -> 480, B -> 720, C -> 960 (i*S//N: 0,1,2).
        assert _run((720,)) == ["B"]
        (entry,) = _entries()
        assert entry["id"] == _id("1002")
        assert entry_slot_minute(entry) == 720
        assert entry["source"] == "kuchnia wikinga"

    def test_run_twice_logs_one_entry(self) -> None:
        """The deterministic id makes a repeat a no-op."""
        assert _run((480, 720)) == ["A", "B"]
        assert _run((480, 720)) == []
        assert [e["id"] for e in _entries()] == [_id("1001"), _id("1002")]

    def test_an_undone_dish_is_not_resurrected(self) -> None:
        """A tombstoned entry still counts as logged."""
        _run((480,))
        entry = find_entry(_id("1001"))
        assert entry is not None
        entry["deleted"] = True
        assert _run((480,)) == []

    def test_peer_copy_merges_to_one_entry(self) -> None:
        """The phone's copy of the same dish collapses with ours by id."""
        _run((480,))
        local = read_raw_log()
        (day,) = local
        peer_entry = {**local[day][0], "time": f"{day}T08:05:00+01:00"}
        peer_entry.pop("hmac", None)
        merged = merge_logs(daylog_to_log(local), daylog_to_log({day: [peer_entry]}))
        entries = [e for es in log_to_daylog(merged).values() for e in es]
        assert [e["id"] for e in entries] == [_id("1001")]


class TestFetchBounded:
    """The fetch sits in front of a fullscreen lock: it must be capped."""

    def test_returns_the_fetch_result(self) -> None:
        """A prompt fetch is passed through."""
        refresh = MagicMock(return_value=(DISHES, None))
        assert fetch_bounded(DAY, refresh=refresh) == (DISHES, None)

    def test_slow_fetch_times_out(self) -> None:
        """A hung panel yields a reason after the cap, not a hang."""

        def slow(_day: date) -> tuple[list[Dish], str | None]:
            time.sleep(2)
            return DISHES, None

        started = time.monotonic()
        dishes, reason = fetch_bounded(DAY, refresh=slow, timeout=0.05)
        assert (dishes, reason is not None) == ([], True)
        assert time.monotonic() - started < 1

    def test_cap_is_five_seconds(self) -> None:
        """The spec's bound."""
        assert FETCH_TIMEOUT_S <= 5.0

    def test_unexpected_error_is_a_reason(self) -> None:
        """A bug in the fetch cannot escape the worker."""
        dishes, reason = fetch_bounded(DAY, refresh=MagicMock(side_effect=OSError("x")))
        assert dishes == []
        assert reason is not None


class TestAutologBeforeLock:
    """The orchestration: fetch, log, report; never raise."""

    written = 0

    def _go(self, fetched: object, due: tuple[int, ...] = (480,)) -> list[str]:
        lines: list[str] = []
        with (
            patch.object(_kuchnia_autolog, "due_slots", return_value=due),
            patch.object(_kuchnia_autolog, "current_slots", return_value=SLOTS),
            patch.object(_kuchnia_autolog, "refresh_delivery", return_value=fetched),
        ):
            self.written = autolog_due_delivery(lines.append)
        return lines

    def test_logs_and_reports(self) -> None:
        """A good fetch logs the due dish and says so."""
        lines = self._go((DISHES, None))
        assert self.written == 1
        assert [e["desc"] for e in _entries()] == ["A"]
        assert lines

    def test_fetch_failure_logs_nothing_and_says_why(self) -> None:
        """Fail closed: no entry, a reason line, the lock proceeds."""
        lines = self._go(([], "panel down"))
        assert self.written == 0
        assert _entries() == []
        assert "panel down" in lines[0]

    def test_nothing_due_skips_the_network(self) -> None:
        """No due slot, no fetch."""
        fetch = MagicMock(return_value=(DISHES, None))
        with (
            patch.object(_kuchnia_autolog, "due_slots", return_value=()),
            patch.object(_kuchnia_autolog, "fetch_bounded", fetch),
        ):
            assert autolog_due_delivery([].append) == 0
        fetch.assert_not_called()

    def test_logging_error_is_swallowed(self) -> None:
        """Even a disk error falls back to the lock instead of crashing the gate."""
        lines: list[str] = []
        with (
            patch.object(_kuchnia_autolog, "due_slots", return_value=(480,)),
            patch.object(
                _kuchnia_autolog, "fetch_bounded", return_value=(DISHES, None)
            ),
            patch.object(
                _kuchnia_autolog, "log_due_dishes", side_effect=OSError("disk")
            ),
        ):
            assert autolog_due_delivery(lines.append) == 0
        assert "disk" in lines[0]


class TestShouldLockAutologs:
    """``_should_lock`` runs the auto-log after the pull, before deciding."""

    def test_autolog_that_clears_the_lock_publishes(self) -> None:
        """No window, but the phone must still hear about the logged meal."""
        publish = MagicMock(return_value=None)
        with (
            patch.object(_cli_gate, "gate_is_due", side_effect=[True, False]),
            patch.object(_cli_gate, "autolog_due_delivery", return_value=1),
            patch.object(_cli_gate, "publish_after_log", publish),
        ):
            assert _cli_gate._should_lock([].append) is False
        publish.assert_called_once()

    def test_failed_autolog_still_locks(self) -> None:
        """Nothing written, still due: the lock opens, no publish."""
        publish = MagicMock(return_value=None)
        with (
            patch.object(_cli_gate, "gate_is_due", side_effect=[True, True]),
            patch.object(_cli_gate, "autolog_due_delivery", return_value=0),
            patch.object(_cli_gate, "publish_after_log", publish),
        ):
            assert _cli_gate._should_lock([].append) is True
        publish.assert_not_called()

    def test_check_mode_never_logs(self) -> None:
        """``gate --check`` is a decision, not a log write."""
        autolog = MagicMock(return_value=1)
        with (
            patch.object(_cli_gate, "gate_is_due", return_value=True),
            patch.object(_cli_gate, "pull_peer_logs", return_value=None),
            patch.object(_cli_gate, "autolog_due_delivery", autolog),
        ):
            assert _cli_gate.cmd_gate([].append, check=True, demo=False) == 1
        autolog.assert_not_called()
