"""The meal server's housekeeping: old answers, failed cleanups, the stream."""

from __future__ import annotations

import asyncio
from datetime import datetime
from typing import TYPE_CHECKING, Any
from unittest.mock import patch

from rtdb_relay.sse import Event

from diet_guard import _claude_sync, _claude_worker
from diet_guard._claude_worker import MealHandler
from diet_guard.tests._claude_worker_fakes import (
    DAY_MS,
    NOW_MS,
    NOW_S,
    RID,
    RID2,
    ROOT,
    FakeRtdb,
    estimator,
    new_server,
    request_fake,
    serve_once,
)

if TYPE_CHECKING:
    from collections.abc import AsyncIterator

    import pytest


def test_old_answers_are_deleted_and_fresh_ones_kept() -> None:
    """Results older than 24 h go; a recent result and its claim stay."""
    fake = FakeRtdb(now_ms=NOW_MS)
    for rid, at in ((RID, NOW_MS - DAY_MS - 5), (RID2, NOW_MS - 1000)):
        fake.raw_set(f"{ROOT}/requests/{rid}/result", {"_e2e": "x", "at": at})
        fake.raw_set(f"{ROOT}/requests/{rid}/claim", {"by": "pc"})

    async def go() -> None:
        db = fake.rtdb()
        server = new_server(db)
        tree = await server._raw.get("requests")
        server.dispatch(tree)
        server.dispatch(tree)  # a second event does not start a second delete
        await asyncio.gather(*server.tasks)
        await db.aclose()

    asyncio.run(go())
    assert fake.raw_get(f"{ROOT}/requests/{RID}") is None
    assert fake.raw_get(f"{ROOT}/requests/{RID2}/claim") == {"by": "pc"}


def test_failed_cleanups_are_only_logged(caplog: pytest.LogCaptureFixture) -> None:
    """A failed payload delete or publish does not undo the answer."""
    fake = request_fake()
    fake.fail[("DELETE", f"/requests/{RID}/req")] = 500
    _claude_sync.publish.return_value = "sync unavailable"
    with caplog.at_level("WARNING"):
        serve_once(fake, estimator())
    assert fake.get(f"{ROOT}/requests/{RID}/result")["status"] == "logged"
    assert "could not delete the request payload" in caplog.text
    assert "post-answer sync skipped" in caplog.text


def test_collect_failure_is_logged_and_the_node_stays(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """The node stays when its delete fails, and its marker is released."""
    fake = FakeRtdb(now_ms=NOW_MS)
    old = NOW_MS - 25 * 3600 * 1000
    fake.raw_set(f"{ROOT}/requests/{RID}/result", {"_e2e": "x", "at": old})
    fake.fail[("DELETE", f"/requests/{RID}")] = 500

    async def go() -> None:
        db = fake.rtdb()
        server = new_server(db)
        server.dispatch(await server._raw.get("requests"))
        await asyncio.gather(*server.tasks)
        assert RID not in server._collecting
        await db.aclose()

    with caplog.at_level("WARNING"):
        asyncio.run(go())
    assert "could not delete the old request" in caplog.text
    assert fake.raw_get(f"{ROOT}/requests/{RID}") is not None


def test_answer_ignores_nodes_that_are_not_pending_requests() -> None:
    """A bad rid, an answered node and a node without req are skipped unpulled."""

    async def go() -> list[object]:
        db = FakeRtdb().rtdb()
        server = new_server(db)
        out = [
            await server.answer("not-a-ulid", {"req": {}}),
            await server.answer(RID, {"req": {}, "result": {}}),
            await server.answer(RID, {"claim": {}}),
        ]
        await db.aclose()
        return out

    assert asyncio.run(go()) == [None, None, None]
    _claude_sync.pull_peers.assert_not_called()


def test_run_mirrors_the_stream_and_dispatches() -> None:
    """Every stream event updates the local tree and serves what is pending."""
    fake = request_fake()
    node = {"req": fake.raw_get(f"{ROOT}/requests/{RID}/req")}

    async def events(*_args: object, **_kwargs: object) -> AsyncIterator[Event]:
        yield Event("put", "/", {RID: node})

    async def go() -> dict[str, Any]:
        db = fake.rtdb()
        server = new_server(db)
        with patch.object(_claude_worker.sse, "listen", events):
            await server.run()
        await asyncio.gather(*server.tasks)
        await db.aclose()
        return server.tree

    assert RID in asyncio.run(go())
    assert fake.get(f"{ROOT}/requests/{RID}/result")["status"] == "logged"


def test_handler_defaults_are_the_real_estimator_and_clock() -> None:
    """A bare MealHandler wires the production estimator, clock and now."""
    handler = MealHandler()
    assert handler._estimate.__name__ == "estimate_meal_async"
    assert isinstance(handler._now(), datetime)
    assert handler._clock() > NOW_S / 2
