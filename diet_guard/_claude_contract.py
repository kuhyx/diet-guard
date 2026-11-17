"""The relay contract's pure parts: body validation, ids, result shapes.

Stdlib only. ``docs/DOCS-claude-relay.md`` is the prose; the shared fixture
``tests/fixtures/claude_relay_contract.json`` drives both this validator and
the phone's, so they cannot drift.
"""

from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass
from typing import Final, Literal
import uuid

TEXT_MAX: Final = 2000
PHOTO_B64_MAX: Final = 600_000
SLOT_MAX: Final = 1439
EXPIRY_MS: Final = 24 * 60 * 60 * 1000

#: Codes the handler raises (``docs/DOCS-claude-relay.md`` section 3).
BAD_REQUEST: Final = "bad_request"
EXPIRED: Final = "expired"

#: A fixed namespace: the same rid always maps to the same entry id.
_ENTRY_NAMESPACE: Final = uuid.UUID("5d9c1a40-6f0e-5c3e-9b57-d1e7a3c0b2f4")
_JPEG_MAGIC: Final = b"\xff\xd8"

Mode = Literal["due", "normal"]


class BadRequestError(ValueError):
    """The request body breaks the contract."""


@dataclass(frozen=True)
class MealRequest:
    """A validated request body.

    Attributes:
        text: The typed meal, trimmed, or None.
        photo: The decoded JPEG bytes, or None.
        client_slot_min: The slot the phone would use; a hint in due mode.
        mode: ``"due"`` (oldest due slot) or ``"normal"`` (nearest slot).
    """

    text: str | None
    photo: bytes | None
    client_slot_min: int
    mode: Mode


def entry_id_for(rid: str) -> str:
    """The log entry id of request ``rid``: a uuid5, so replays find it."""
    return str(uuid.uuid5(_ENTRY_NAMESPACE, rid))


def _photo(value: object) -> bytes | None:
    """The decoded JPEG, None when absent."""
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > PHOTO_B64_MAX:
        msg = "photo_jpeg_b64 is not a base64 string within the size cap"
        raise BadRequestError(msg)
    try:
        data = base64.b64decode(value, validate=True)
    except binascii.Error as err:
        msg = "photo_jpeg_b64 is not valid base64"
        raise BadRequestError(msg) from err
    if not data.startswith(_JPEG_MAGIC):
        msg = "photo_jpeg_b64 is not a JPEG"
        raise BadRequestError(msg)
    return data


def _text(value: object) -> str | None:
    """The trimmed text, None when absent."""
    if value is None:
        return None
    if not isinstance(value, str):
        msg = "text is not a string"
        raise BadRequestError(msg)
    trimmed = value.strip()
    if not trimmed or len(trimmed) > TEXT_MAX:
        msg = f"text must be 1..{TEXT_MAX} characters"
        raise BadRequestError(msg)
    return trimmed


def parse_body(body: dict[str, object]) -> MealRequest:
    """Validate a request body.

    Raises:
        BadRequestError: any field breaks the contract, or there is neither
            text nor photo to estimate.
    """
    text = _text(body.get("text"))
    photo = _photo(body.get("photo_jpeg_b64"))
    if text is None and photo is None:
        msg = "neither text nor photo"
        raise BadRequestError(msg)
    slot = body.get("client_slot_min")
    if isinstance(slot, bool) or not isinstance(slot, int) or not 0 <= slot <= SLOT_MAX:
        msg = f"client_slot_min must be an int in 0..{SLOT_MAX}"
        raise BadRequestError(msg)
    mode = body.get("mode")
    if mode == "due":
        return MealRequest(text, photo, slot, "due")
    if mode == "normal":
        return MealRequest(text, photo, slot, "normal")
    msg = "mode must be 'due' or 'normal'"
    raise BadRequestError(msg)


def is_expired(created_ms: object, now_ms: float) -> bool:
    """Whether a request created at ``created_ms`` is older than 24 h.

    A missing or non-numeric ``created`` counts as expired: the request has no
    server timestamp, so it cannot be trusted to be fresh (fail closed).
    """
    if isinstance(created_ms, bool) or not isinstance(created_ms, (int, float)):
        return True
    return now_ms - created_ms > EXPIRY_MS
