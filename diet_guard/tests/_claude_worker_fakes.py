"""Shared setup for the meal-server tests: one request, one in-memory RTDB.

The RTDB is ``rtdb_relay``'s own fake. It is rooted at the tutor's layout,
which has the same ``requests/*/req | claim | result`` rules as this relay's,
so the server logic runs against realistic sealing, ETags and SSE; the real
layout is pinned separately by ``test_claude_relay_contract.py``.
"""

from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any
from unittest.mock import AsyncMock

from rtdb_relay.tests._fake_rtdb import ROOT, FakeRtdb

from diet_guard._claude_schema import Estimate
from diet_guard._claude_worker import MealHandler, MealServer
from diet_guard._state import load_log

if TYPE_CHECKING:
    from rtdb_relay.rtdb import Rtdb

__all__ = ["ROOT", "FakeRtdb"]

RID = "01J0000000000000000000000R"
RID2 = "01J0000000000000000000000S"
NOW_S = 1_800_000_000.0
NOW_MS = int(NOW_S * 1000)
DAY_MS = 24 * 3600 * 1000
NOON = datetime(2026, 11, 17, 12, 30, tzinfo=UTC)
EST = Estimate("2 jajka", 190.0, 410.0, 17.5, 22.0, 26.0, None)
BODY: dict[str, Any] = {"text": "2 jajka", "client_slot_min": 720, "mode": "normal"}


def put(fake: FakeRtdb, rid: str, body: dict[str, Any], age_ms: int = 0) -> None:
    """A phone writes one request."""
    req = {
        "kind": "meal",
        "dev": "d",
        "created": NOW_MS - age_ms,
        "sent_at": 1,
        "body": body,
    }
    fake.set(f"{ROOT}/requests/{rid}/req", req)


def request_fake(
    body: dict[str, Any] | None = None, rid: str = RID, age_ms: int = 0
) -> FakeRtdb:
    """A database holding one pending request."""
    fake = FakeRtdb(now_ms=NOW_MS)
    put(fake, rid, BODY if body is None else body, age_ms)
    return fake


def estimator(result: object = EST) -> AsyncMock:
    """A fake model: returns ``result``, or raises it when it is an exception."""
    if isinstance(result, Exception):
        return AsyncMock(side_effect=result)
    return AsyncMock(return_value=result)


def new_server(db: Rtdb, estimate: AsyncMock | None = None) -> MealServer:
    """A server on ``db`` with a fixed clock and an instant retry pause."""
    handler = MealHandler(
        estimate or estimator(), now=lambda: NOON, clock=lambda: NOW_S
    )
    server = MealServer(db, "pc", handler, now=lambda: NOW_S)
    server._sleep = AsyncMock()
    return server


def serve_once(
    fake: FakeRtdb, estimate: AsyncMock, rid: str = RID
) -> tuple[MealServer, dict[str, Any] | None]:
    """Answer ``rid`` once and let its background work finish."""
    box: list[MealServer] = []

    async def go() -> dict[str, Any] | None:
        db = fake.rtdb()
        server = new_server(db, estimate)
        box.append(server)
        node = await server._raw.get(f"requests/{rid}")
        out = await server.answer(rid, node if isinstance(node, dict) else {})
        await asyncio.gather(*server.tasks)
        await db.aclose()
        return out

    result = asyncio.run(go())
    return box[0], result


def entries() -> list[dict[str, Any]]:
    """Every live entry of the (redirected) food log."""
    return [e for day in load_log().values() for e in day]
