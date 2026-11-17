"""The meal server end to end: one request in, one answer and one entry out."""

from __future__ import annotations

import asyncio
from typing import Any
from unittest.mock import patch

import pytest

from diet_guard import _claude_sync, _claude_worker
from diet_guard._claude_contract import entry_id_for, parse_body
from diet_guard._claude_estimate import EstimateError
from diet_guard._claude_log import log_estimate
from diet_guard._slot_wire import entry_slot_minute
from diet_guard.tests._claude_worker_fakes import (
    BODY,
    DAY_MS,
    EST,
    NOON,
    NOW_MS,
    RID,
    RID2,
    ROOT,
    entries,
    estimator,
    new_server,
    put,
    request_fake,
    serve_once,
)


def test_a_request_is_logged_answered_trimmed_and_published() -> None:
    """Result first, then req is deleted, claim and result stay, publish ran."""
    fake = request_fake()
    _, out = serve_once(fake, estimator())
    assert out is not None
    result = fake.get(f"{ROOT}/requests/{RID}/result")
    assert result["ok"] is True
    assert result["status"] == "logged"
    assert result["id"] == RID
    assert result["entry_id"] == entry_id_for(RID)
    assert result["kcal"] == 410.0
    assert result["at"] == NOW_MS
    assert fake.get(f"{ROOT}/requests/{RID}/req") is None
    assert fake.get(f"{ROOT}/requests/{RID}/claim")["by"] == "pc"
    (entry,) = entries()
    assert entry["source"] == "claude"
    _claude_sync.pull_peers.assert_called_once_with()
    _claude_sync.publish.assert_called_once_with()


def test_a_failed_pull_leaves_the_request_pending_and_retries() -> None:
    """No claim, no result, req kept; the retry timer serves it once sync is back."""
    fake = request_fake()
    estimate = estimator()
    _claude_sync.pull_peers.return_value = "sync unavailable (locked)"

    async def go() -> list[float]:
        db = fake.rtdb()
        server = new_server(db, estimate)
        sleeps: list[float] = []
        gate = asyncio.Event()

        async def sleep(seconds: float) -> None:
            sleeps.append(seconds)
            await gate.wait()

        server._sleep = sleep
        server.tree = await server._raw.get("requests")
        node = server.tree[RID]
        assert await server.answer(RID, node) is None
        assert await server.answer(RID, node) is None  # one retry timer at most
        assert fake.get(f"{ROOT}/requests/{RID}/claim") is None
        assert fake.get(f"{ROOT}/requests/{RID}/result") is None
        estimate.assert_not_awaited()
        _claude_sync.pull_peers.return_value = None
        gate.set()
        assert server._retry is not None
        await server._retry
        await asyncio.gather(*server.tasks)
        await db.aclose()
        return sleeps

    assert asyncio.run(go()) == [_claude_worker.RETRY_S]
    assert fake.get(f"{ROOT}/requests/{RID}/result")["status"] == "logged"


@pytest.mark.parametrize(
    "code", ["estimate_failed", "estimate_timeout", "estimate_invalid"]
)
def test_an_estimator_failure_is_an_error_result_and_nothing_is_logged(
    code: str,
) -> None:
    """Fail closed: error result with retry, no entry, payload still deleted."""
    fake = request_fake()
    serve_once(fake, estimator(EstimateError(code, "boom")))
    result = fake.get(f"{ROOT}/requests/{RID}/result")
    assert result["ok"] is False
    assert (result["status"], result["error_code"], result["code"]) == (
        "error",
        code,
        code,
    )
    assert result["retry"] is True
    assert entries() == []
    assert fake.get(f"{ROOT}/requests/{RID}/req") is None


@pytest.mark.parametrize(
    ("body", "age_ms", "code"),
    [
        ({"mode": "due", "client_slot_min": 5}, 0, "bad_request"),
        (BODY, DAY_MS + 1, "expired"),
    ],
)
def test_bad_and_expired_requests_are_answered_not_estimated(
    body: dict[str, Any], age_ms: int, code: str
) -> None:
    """No model call and no entry for a request that breaks the contract."""
    fake = request_fake(body, age_ms=age_ms)
    estimate = estimator()
    serve_once(fake, estimate)
    result = fake.get(f"{ROOT}/requests/{RID}/result")
    assert (result["status"], result["error_code"], result["retry"]) == (
        "error",
        code,
        False,
    )
    estimate.assert_not_awaited()
    assert entries() == []


def test_a_crash_between_log_and_result_is_replayed_without_a_second_entry() -> None:
    """The entry exists but no result: the replay answers from the log."""
    fake = request_fake()
    log_estimate(RID, EST, parse_body(BODY), NOON)
    estimate = estimator()
    serve_once(fake, estimate)
    estimate.assert_not_awaited()
    assert fake.get(f"{ROOT}/requests/{RID}/result")["entry_id"] == entry_id_for(RID)
    assert len(entries()) == 1


def test_a_duplicate_dispatch_of_one_request_logs_one_entry() -> None:
    """The same stale node served twice (own claim taken over): one entry."""
    fake = request_fake()
    estimate = estimator()

    async def go() -> None:
        db = fake.rtdb()
        server = new_server(db, estimate)
        node = await server._raw.get(f"requests/{RID}")
        first = await server.answer(RID, node)
        second = await server.answer(RID, node)
        assert first is not None
        assert second is not None
        await asyncio.gather(*server.tasks)
        await db.aclose()

    asyncio.run(go())
    assert len(entries()) == 1
    assert estimate.await_count == 1


def test_two_requests_take_two_different_due_slots() -> None:
    """Each due-mode request takes the oldest slot still due when it runs."""
    fake = request_fake(rid=RID)
    put(fake, RID2, {**BODY, "mode": "due"})
    with patch("diet_guard._claude_log.due_slots", side_effect=[(480, 720), (720,)]):
        serve_once(fake, estimator(), RID)
        serve_once(fake, estimator(), RID2)
    slots = sorted(entry_slot_minute(e) or 0 for e in entries())
    assert slots == [480, 720]


def test_a_request_claimed_by_another_worker_is_left_alone() -> None:
    """A live lease elsewhere: no estimate, no result, the payload stays."""
    fake = request_fake()
    lease = {
        "by": "other-pc",
        "lease_until": NOW_MS + 200_000,
        "attempt": 1,
        "phase": "x",
        "at": 1,
    }
    fake.set(f"{ROOT}/requests/{RID}/claim", lease)
    estimate = estimator()
    _, out = serve_once(fake, estimate)
    assert out is None
    estimate.assert_not_awaited()
    assert fake.get(f"{ROOT}/requests/{RID}/result") is None
    assert fake.get(f"{ROOT}/requests/{RID}/req") is not None
    _claude_sync.publish.assert_not_called()
