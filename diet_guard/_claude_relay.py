"""``python -m diet_guard claude-worker``: connect, serve, never idle-poll.

One SSE stream on ``requests`` does the waiting (``rtdb_relay.sse`` reconnects
forever with backoff). The only timers are fault retries: an unconfigured or
locked relay (no session, no passphrase, wrong key) writes nothing and is
tried again every :data:`RETRY_S`.
"""

from __future__ import annotations

import asyncio
import logging
from typing import TYPE_CHECKING, Final

from rtdb_relay.sse import StreamCancelledError

from diet_guard import _claude_connect, _device
from diet_guard._claude_worker import MealHandler, MealServer

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable

RETRY_S: Final = 60.0
_logger = logging.getLogger(__name__)


async def serve(
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> None:
    """Connect and serve until cancelled; a setup failure waits and retries."""
    worker = f"claude-{_device.device_id()}"
    while True:
        try:
            rtdb = await _claude_connect.connect_sealed()
        except _claude_connect.RelaySetupError as err:
            _logger.warning("relay not started, nothing written: %s", err)
            await sleep(RETRY_S)
            continue
        try:
            await MealServer(rtdb, worker, MealHandler()).run()
        finally:
            await rtdb.aclose()


def main() -> int:
    """Run the worker; 0 on Ctrl-C, 1 when RTDB cancelled the stream."""
    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(name)s: %(message)s"
    )
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        return 0
    except StreamCancelledError:
        _logger.exception("the rules refuse the relay path")
        return 1
    return 0
