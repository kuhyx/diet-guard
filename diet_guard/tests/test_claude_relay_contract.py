"""The shared contract fixture: sealed bytes, layout, ids and body rules."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from crdt_sync import E2eCipher
import pytest
from rtdb_relay.layout import E2eLayoutError, Layout
from rtdb_relay.seal import SEALED, Sealer

from diet_guard._claude_contract import (
    BadRequestError,
    entry_id_for,
    is_expired,
    parse_body,
)
from diet_guard._claude_layout import E2E_LAYOUT, KIND, LAYOUT, ROOT
from diet_guard._sync_e2e import DIET_LAYOUT

FIXTURE: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[2]
        / "tests/fixtures/claude_relay_contract.json"
    ).read_text(encoding="utf-8")
)


def _sealer(layout: Layout = LAYOUT) -> Sealer:
    return Sealer(E2eCipher(bytes.fromhex(FIXTURE["key_hex"])), layout)


def test_root_and_header_are_the_existing_ones() -> None:
    """The relay shares diet_guard's e2e header: same salt, same key."""
    assert FIXTURE["root"] == ROOT
    assert E2E_LAYOUT.e2e_path == FIXTURE["header_path"] == DIET_LAYOUT.e2e_path
    assert KIND == "meal"


def test_layout_matches_the_fixture() -> None:
    """The sealed units and the one clear node are exactly the contract's."""
    assert set(LAYOUT.clear) == set(FIXTURE["layout"]["clear"])
    assert {k: sorted(v) for k, v in LAYOUT.units.items()} == FIXTURE["layout"]["units"]


@pytest.mark.parametrize(
    "node",
    [FIXTURE["request"], *FIXTURE["results"].values()],
    ids=["request", "logged", "error", "expired"],
)
def test_sealed_nodes_open_to_the_contract_plaintext(node: dict[str, Any]) -> None:
    """A phone-sealed node opens to its plaintext plus its clear siblings."""
    stored = node["node"]
    assert SEALED in stored
    assert {k: v for k, v in stored.items() if k != SEALED} == node["clear"]
    opened = _sealer().open(node["path"], stored)
    assert opened == {**node["plain"], **node["clear"]}


def test_a_blob_moved_to_another_path_does_not_open() -> None:
    """The unit path is the AAD: a copied request is read as absent."""
    moved = FIXTURE["request"]["node"]
    assert _sealer().open("requests/01JD5Z8K3M7Q2W9XH4TBN6VR0F/req", moved) is None


def test_the_sealer_refuses_a_path_outside_the_contract() -> None:
    """Everything else is fail closed: no rule, no write."""
    with pytest.raises(E2eLayoutError):
        _sealer().seal("presence/workers/pc", {"x": 1})


def test_entry_id_is_the_fixtures_uuid5() -> None:
    """The rid maps to one fixed entry id on both devices."""
    assert entry_id_for(FIXTURE["rid"]) == FIXTURE["entry_id"]
    assert entry_id_for("a") != entry_id_for("b")


@pytest.mark.parametrize("case", FIXTURE["body_cases"], ids=lambda c: c["name"])
def test_body_cases(case: dict[str, Any]) -> None:
    """The phone's and the PC's validators agree on every shared case."""
    if case["valid"]:
        assert parse_body(case["body"]).mode == case["body"]["mode"]
    else:
        with pytest.raises(BadRequestError):
            parse_body(case["body"])


def test_parsed_body_carries_text_photo_and_slot() -> None:
    """A valid body is trimmed and its photo decoded."""
    body = FIXTURE["request"]["plain"]["body"]
    parsed = parse_body({**body, "text": "  banan  "})
    assert parsed.text == "banan"
    assert parsed.photo is not None
    assert parsed.photo.startswith(b"\xff\xd8")
    assert parsed.client_slot_min == 720


def test_expiry_is_24_hours_of_server_time_and_fails_closed() -> None:
    """Older than 24 h, or no usable ``created``, is expired."""
    day = 24 * 3600 * 1000
    assert not is_expired(1_000, 1_000 + day)
    assert is_expired(1_000, 1_001 + day)
    for bad in (None, "x", True):
        assert is_expired(bad, 5)


@pytest.mark.parametrize(
    "body",
    [
        {"text": 5, "client_slot_min": 1, "mode": "due"},
        {"photo_jpeg_b64": 5, "client_slot_min": 1, "mode": "due"},
        {"photo_jpeg_b64": "A" * 600_001, "client_slot_min": 1, "mode": "due"},
        {"text": "a", "client_slot_min": True, "mode": "due"},
    ],
)
def test_wrongly_typed_or_oversize_fields_are_refused(body: dict[str, Any]) -> None:
    """Types and size caps beyond the shared cases."""
    with pytest.raises(BadRequestError):
        parse_body(body)
