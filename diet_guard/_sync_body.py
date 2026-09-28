"""Pull/merge/push for the Body document, plus the two things that feed it.

Runs inside the full sync tick (:func:`diet_guard._sync.run_sync`), after
the budget. Order matters:

1. **Ingest the phone's weigh-ins** from wake-alarm's record
   (:mod:`diet_guard._body_ingest`), so a morning weigh-in lands in the log
   even when the phone's diet-guard app never opened.
2. **Publish workouts** (:mod:`diet_guard._activity_sources`) -- PC only, and
   only when a source exists here, so a machine without RunnerUp or
   screen-locker can never publish an empty list over the real one.
3. **Merge** with every peer's ``body.json`` (per-field LWW), persist, push.

Body is a Firebase-era document, so peers are read from the primary only
(:func:`diet_guard._sync_banks._primary_only_text`).
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING

from crdt_sync import merge_logs

from diet_guard._activity_sources import collect_sessions, sources_available
from diet_guard._body_activity_store import set_activity
from diet_guard._body_ingest import fetch_alarm_logs, weight_candidates
from diet_guard._body_store import apply_weight_candidates, read_body, write_body
from diet_guard._device import device_identity
from diet_guard._state import now_local
from diet_guard._sync_banks import _primary_only_text
from diet_guard._sync_paths import _device_body_path
from diet_guard.sync_merge._body import (
    body_to_log,
    encode_body_for_push,
    log_to_body,
    parse_remote_body,
)

if TYPE_CHECKING:
    from collections.abc import Sequence

    from crdt_sync import RemoteStore

_logger = logging.getLogger(__name__)


def publish_activity() -> None:
    """Refresh the published workouts from this machine's sources, if any."""
    if not sources_available():
        return
    if set_activity(collect_sessions(now_local().date())):
        _logger.info("activity: published updated workout sessions")


def sync_body(client: RemoteStore, device_ids: Sequence[str]) -> None:
    """Ingest weigh-ins, publish workouts, then merge and push ``body.json``."""
    applied = apply_weight_candidates(weight_candidates(fetch_alarm_logs(client)))
    if applied:
        _logger.info("body: %d weigh-in(s) from the phone", applied)
    publish_activity()
    identity = device_identity()
    merged = body_to_log(read_body())
    for device_id in device_ids:
        if identity.is_own(device_id):
            continue
        text = _primary_only_text(client, _device_body_path(device_id))
        if text is None:
            continue
        try:
            merged = merge_logs(merged, parse_remote_body(text))
        except TypeError, KeyError, ValueError, json.JSONDecodeError:
            _logger.warning(
                "Unparsable body document from device %r, skipping", device_id
            )
    if not merged:
        return
    write_body(log_to_body(merged))
    client.put_file_text(
        _device_body_path(identity.device_id),
        encode_body_for_push(merged),
        message="diet_guard sync: body",
    )
