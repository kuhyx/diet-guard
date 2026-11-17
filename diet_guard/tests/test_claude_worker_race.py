"""Two close requests must never lose an entry to a pull or a publish.

The narrow pull and the full tick each read the food log, merge and write it
back; ``log_meal_as`` appends to it. Two of those at once lose the append: the
phone is told "logged" and the only copy is gone. conftest replaces pull and
publish with mocks, so this test gives them the read-pause-write shape of the
real ones.
"""

from __future__ import annotations

import asyncio
import time
from typing import TYPE_CHECKING, Any
from unittest.mock import AsyncMock

from diet_guard import _claude_sync
from diet_guard._state_sync import read_raw_log, write_raw_log
from diet_guard.tests._claude_worker_fakes import (
    BODY,
    EST,
    RID,
    RID2,
    entries,
    new_server,
    put,
    request_fake,
)

if TYPE_CHECKING:
    from diet_guard._claude_schema import Estimate


def _merge_like_a_sync_tick(*_args: object) -> None:
    """Read the log, take a while merging, write it back: what a tick does."""
    log = read_raw_log()
    time.sleep(0.2)
    write_raw_log(log)


async def _slow_for_b(text: str | None, photo: bytes | None) -> Estimate:
    """The second request's estimate finishes while the first one publishes."""
    del photo
    if text == "slow":
        await asyncio.sleep(0.05)
    return EST


def test_a_publish_in_flight_does_not_swallow_the_next_request() -> None:
    """Both entries survive when request B logs during request A's publish."""
    _claude_sync.pull_peers.side_effect = _merge_like_a_sync_tick
    _claude_sync.publish.side_effect = _merge_like_a_sync_tick
    fake = request_fake({**BODY, "text": "fast"}, rid=RID)
    put(fake, RID2, {**BODY, "text": "slow"})

    async def go() -> None:
        db = fake.rtdb()
        server = new_server(db, AsyncMock(side_effect=_slow_for_b))
        tree: dict[str, Any] = await server._raw.get("requests")
        server.dispatch(tree)
        while server.tasks:
            await asyncio.gather(*list(server.tasks))
        await db.aclose()

    asyncio.run(go())
    assert len(entries()) == 2
