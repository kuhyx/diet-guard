"""Serving meal requests: validate, estimate, log, answer, then publish.

``MealServer`` is ``rtdb_relay``'s ``RequestServer`` with the four things this
relay adds on top (``docs/DOCS-claude-relay.md`` section 5):

* a narrow peer pull before a request is claimed; a failed pull leaves the
  request pending (no claim, no answer, no model cost) and retries later;
* the request's id and server ``created`` time reach the handler;
* ``req`` (the photo) is deleted once the result is written; the node keeps
  ``claim`` and ``result`` until the phone deletes it or 24 h pass;
* the full sync tick runs *after* the answer, in the background.

``MealHandler`` is the handler for kind ``meal``.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import TYPE_CHECKING, Any, Final

from rtdb_relay import mirror, sse
from rtdb_relay.lease import ms, valid_rid
from rtdb_relay.rtdb import RtdbError
from rtdb_relay.server import RequestError, RequestServer

from diet_guard import _claude_sync
from diet_guard._claude_contract import (
    BAD_REQUEST,
    EXPIRED,
    EXPIRY_MS,
    BadRequestError,
    is_expired,
    parse_body,
)
from diet_guard._claude_estimate import EstimateError, estimate_meal_async
from diet_guard._claude_layout import KIND
from diet_guard._claude_log import already_logged, log_estimate
from diet_guard._state import now_local

if TYPE_CHECKING:
    from collections.abc import Awaitable, Callable
    from datetime import datetime

    from rtdb_relay.lease import Lease
    from rtdb_relay.rtdb import Rtdb

    from diet_guard._claude_schema import Estimate

    type Estimator = Callable[[str | None, bytes | None], Awaitable[Estimate]]

#: Seconds before a request left pending by a failed pull is tried again.
RETRY_S: Final = 30.0
_logger = logging.getLogger(__name__)


class MealHandler:
    """The handler of kind ``meal``: body in, ``logged`` result data out."""

    def __init__(
        self,
        estimate: Estimator = estimate_meal_async,
        now: Callable[[], datetime] = now_local,
        clock: Callable[[], float] = time.time,
    ) -> None:
        """Estimate with ``estimate``; ``now`` stamps the entry, ``clock`` ages it."""
        self._estimate = estimate
        self._now = now
        self._clock = clock
        # Two requests must not take the same due slot.
        self._log_lock = asyncio.Lock()

    async def handle(self, body: dict[str, Any]) -> dict[str, Any]:
        """Serve one request body (``rid`` and ``created`` injected by the server)."""
        rid = str(body.get("rid"))
        if (done := await asyncio.to_thread(already_logged, rid)) is not None:
            _logger.info("request %s was logged before: answering from the log", rid)
            return done
        if is_expired(body.get("created"), self._clock() * 1000):
            raise RequestError(EXPIRED, "request older than 24 h")
        try:
            request = parse_body(body)
        except BadRequestError as err:
            raise RequestError(BAD_REQUEST, str(err)) from err
        try:
            estimate = await self._estimate(request.text, request.photo)
        except EstimateError as err:
            raise RequestError(err.code, str(err), retry=True) from err
        async with self._log_lock:
            return await asyncio.to_thread(
                log_estimate, rid, estimate, request, self._now()
            )


class MealServer(RequestServer):
    """``RequestServer`` plus the pull, the cleanup and the late publish."""

    def __init__(
        self,
        rtdb: Rtdb,
        worker: str,
        handler: MealHandler,
        now: Callable[[], float] = time.time,
    ) -> None:
        """Serve kind ``meal`` with ``handler`` as ``worker``."""
        super().__init__(rtdb, worker, {KIND: handler.handle}, now)
        # Replaceable (tests): the pause before a pending request is retried.
        self._sleep: Callable[[float], Awaitable[None]] = asyncio.sleep
        self.tree: dict[str, Any] = {}
        self._retry: asyncio.Task[None] | None = None
        self._collecting: set[str] = set()
        self._publish_lock = asyncio.Lock()

    async def answer(self, rid: str, node: dict[str, Any]) -> dict[str, Any] | None:
        """Pull, serve, then clean up and publish; None when not ours to answer."""
        if not valid_rid(rid) or "result" in node or "req" not in node:
            return None
        if (reason := await asyncio.to_thread(_claude_sync.pull_peers)) is not None:
            _logger.warning("not serving %s, request stays pending: %s", rid, reason)
            self._retry_later()
            return None
        result = await super().answer(rid, node)
        if result is not None:
            await self._drop_request(rid)
            self._start(self._publish())
        return result

    async def _run(
        self, lease: Lease, kind: str, req: dict[str, Any]
    ) -> dict[str, Any]:
        """Hand the handler the rid and the server's ``created``; add ``status``."""
        body = req.get("body")
        body = body if isinstance(body, dict) else {}
        enriched = {
            **req,
            "body": {**body, "rid": lease.rid, "created": req.get("created")},
        }
        result = await super()._run(lease, kind, enriched)
        if result.get("ok"):
            return {**result, "status": "logged", "id": lease.rid}
        return {
            **result,
            "status": "error",
            "id": lease.rid,
            "error_code": result.get("code"),
        }

    async def _drop_request(self, rid: str) -> None:
        """Delete ``req`` (the photo): useless once the result is out."""
        try:
            await self.rtdb.delete(f"requests/{rid}/req")
        except RtdbError as err:
            _logger.warning("could not delete the request payload of %s: %s", rid, err)

    async def _publish(self) -> None:
        """The full sync tick, after the answer; an outage is only logged."""
        async with self._publish_lock:
            reason = await asyncio.to_thread(_claude_sync.publish)
        if reason is not None:
            _logger.warning("post-answer sync skipped: %s", reason)

    def _start(self, work: Awaitable[None]) -> None:
        """Run ``work`` in the background, remembered so it is not collected."""
        task = asyncio.ensure_future(work)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    def _retry_later(self) -> None:
        """Try the pending requests again in :data:`RETRY_S` (one timer at most)."""
        if self._retry is None or self._retry.done():
            self._retry = asyncio.ensure_future(self._retry_after())

    async def _retry_after(self) -> None:
        await self._sleep(RETRY_S)
        self.dispatch(self.tree)

    def dispatch(self, tree: dict[str, Any]) -> None:
        """Serve what is pending, and drop answers older than 24 h."""
        super().dispatch(tree)
        cutoff = ms(self._now()) - EXPIRY_MS
        for rid, node in tree.items():
            result = node.get("result") if isinstance(node, dict) else None
            at = result.get("at") if isinstance(result, dict) else None
            old = (
                isinstance(at, (int, float))
                and not isinstance(at, bool)
                and at < cutoff
            )
            if old and valid_rid(rid) and rid not in self._collecting:
                self._collecting.add(rid)
                self._start(self._collect(rid))

    async def _collect(self, rid: str) -> None:
        """Delete one answered request node (a failure is retried next event)."""
        try:
            await self.rtdb.delete(f"requests/{rid}")
        except RtdbError as err:
            _logger.warning("could not delete the old request %s: %s", rid, err)
        finally:
            self._collecting.discard(rid)

    async def run(self) -> None:
        """Watch ``requests`` (raw, so sealing is checked) until cancelled."""
        self.tree = {}
        async for event in sse.listen(self._raw, "requests"):
            self.tree = mirror.apply(self.tree, event)
            self.dispatch(self.tree)
