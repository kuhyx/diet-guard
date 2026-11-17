#!/usr/bin/env python3
"""Regenerate the shared "send to Claude" relay contract fixture.

``tests/fixtures/claude_relay_contract.json`` is read by the Python tests
(``diet_guard/tests/test_claude_relay_contract.py``) and by the phone's Dart
tests, so the PC worker and the phone app seal, open and validate the same
bytes. The wire format is ``docs/DOCS-claude-relay.md``.

Sealed blobs use a fixed test key but a random nonce, so every run changes the
blob bytes; the plaintext and the clear siblings stay put. Readers *open* the
blobs and compare plaintext, they never compare ciphertext.

Run from the repo root:

    .venv/bin/python scripts/build_claude_relay_fixture.py
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from crdt_sync import E2eCipher, E2eLayout
from rtdb_relay.layout import Layout
from rtdb_relay.seal import Sealer

OUT = Path(__file__).resolve().parent.parent / "tests" / "fixtures"
OUT_FILE = OUT / "claude_relay_contract.json"

KEY_HEX = bytes(range(32)).hex()
RID = "01JD5Z8K3M7Q2W9XH4TBN6VR0E"
ROOT = E2eLayout.of("diet-guard-sync/claude").prefix
HEADER = E2eLayout.of("diet-guard-sync/devices").e2e_path
CLEAR = ("requests/*/claim",)
UNITS = {"requests/*/req": ["created"], "requests/*/result": ["at"]}
CREATED_MS = 1_795_000_000_000
PHOTO_B64 = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgK"
    "CgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/"
)

REQUEST: dict[str, Any] = {
    "kind": "meal",
    "dev": "6f1f0c1e-5b0a-4a3e-9f57-2c1d6f0e9a11",
    "sent_at": CREATED_MS - 40,
    "body": {
        "text": "2 jajka sadzone i kromka chleba",
        "photo_jpeg_b64": PHOTO_B64,
        "client_slot_min": 720,
        "mode": "due",
    },
}
LOGGED: dict[str, Any] = {
    "ok": True,
    "kind": "meal",
    "status": "logged",
    "id": RID,
    "entry_id": "7b0c5d52-8a43-5a63-b6f5-7d0f1c0e2a44",
    "desc": "2 jajka sadzone i kromka chleba",
    "grams": 190,
    "kcal": 410,
    "protein_g": 17.5,
    "carbs_g": 22,
    "fat_g": 26,
    "slot_min": 720,
    "time": "2026-11-17T12:03:41+01:00",
}
ERROR: dict[str, Any] = {
    "ok": False,
    "kind": "meal",
    "status": "error",
    "id": RID,
    "error_code": "estimate_failed",
    "code": "estimate_failed",
    "error": "model returned no valid JSON",
    "retry": True,
}
EXPIRED: dict[str, Any] = {
    **ERROR,
    "error_code": "expired",
    "code": "expired",
    "error": "request older than 24 h",
    "retry": False,
}
CLAIM: dict[str, Any] = {
    "by": "pc-worker",
    "lease_until": CREATED_MS + 300_000,
    "attempt": 1,
    "phase": "claimed",
    "at": CREATED_MS + 10,
}


def _case(name: str, body: dict[str, object], *, valid: bool) -> dict[str, Any]:
    return {"name": name, "valid": valid, "body": body}


def _body(**fields: object) -> dict[str, object]:
    return {"client_slot_min": 480, "mode": "due", **fields}


# Body validation, shared by the PC (``_claude_contract``) and the phone.
BODY_CASES: list[dict[str, Any]] = [
    _case("text only", _body(text="banan", mode="normal"), valid=True),
    _case("photo only", _body(photo_jpeg_b64=PHOTO_B64, client_slot_min=0), valid=True),
    _case("both", REQUEST["body"], valid=True),
    _case("nothing to estimate", _body(), valid=False),
    _case("blank text", _body(text="   "), valid=False),
    _case("text too long", _body(text="x" * 2001), valid=False),
    _case("bad mode", _body(text="a", mode="now"), valid=False),
    _case("slot out of range", _body(text="a", client_slot_min=1440), valid=False),
    _case("slot not int", _body(text="a", client_slot_min="480"), valid=False),
    _case("missing slot", {"text": "a", "mode": "due"}, valid=False),
    _case("photo not jpeg", _body(photo_jpeg_b64="aGVsbG8="), valid=False),
    _case("photo not base64", _body(photo_jpeg_b64="@@@"), valid=False),
]


def _sealer() -> Sealer:
    layout = Layout(
        root=ROOT,
        clear=CLEAR,
        units={k: frozenset(v) for k, v in UNITS.items()},
    )
    return Sealer(E2eCipher(bytes.fromhex(KEY_HEX)), layout)


def _node(
    sealer: Sealer, path: str, plain: dict[str, Any], clear: dict[str, Any]
) -> dict[str, Any]:
    """A stored unit: ``plain`` sealed for ``path`` plus its clear siblings."""
    stored = sealer.seal(path, {**plain, **clear})
    return {"path": path, "node": stored, "plain": plain, "clear": clear}


def build() -> dict[str, Any]:
    """The whole fixture as a JSON-ready dict."""
    sealer = _sealer()
    base = f"requests/{RID}"
    answered = {"at": CREATED_MS + 9000}
    return {
        "version": 1,
        "root": ROOT,
        "header_path": HEADER,
        "key_hex": KEY_HEX,
        "rid": RID,
        "layout": {"clear": list(CLEAR), "units": UNITS},
        "limits": {
            "text_max": 2000,
            "photo_b64_max": 600_000,
            "slot_max": 1439,
            "expiry_hours": 24,
            "estimate_timeout_s": 45,
        },
        "request": _node(sealer, f"{base}/req", REQUEST, {"created": CREATED_MS}),
        "claim": {"path": f"{base}/claim", "node": CLAIM},
        "results": {
            "logged": _node(sealer, f"{base}/result", LOGGED, answered),
            "error": _node(sealer, f"{base}/result", ERROR, answered),
            "expired": _node(sealer, f"{base}/result", EXPIRED, answered),
        },
        "body_cases": BODY_CASES,
    }


def main() -> None:
    """Write the fixture."""
    OUT.mkdir(parents=True, exist_ok=True)
    text = json.dumps(build(), indent=1, ensure_ascii=False)
    OUT_FILE.write_text(text + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
