"""The catering credential's own synced document.

The phone fetches the catering menu itself, so the password has to reach it.
These tests pin the three things that would silently break that:

* a device with no credential contributes nothing rather than clobbering a
  peer's real value with an empty string,
* the two halves carry independent clocks, and
* a device that knows nothing about this document still **relays** it.

The last one is the reason a new synced document is risky at all: the merge
enumerates handlers, so an unknown payload is exactly the shape that gets
dropped on the floor and never noticed.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any
from unittest.mock import patch

from crdt_sync import Hlc, Record, merge_logs
import pytest

from diet_guard.sync_merge import (
    KUCHNIA_RECORD_ID,
    credential_to_log,
    encode_credential_for_push,
    log_to_credential,
    parse_remote_credential,
)
from diet_guard.sync_merge._kuchnia import PASSWORD_FIELD_NAME, USERNAME_FIELD_NAME

_EDITED = "2026-08-23T10:00:00+02:00"


def test_round_trips_through_the_wire_format() -> None:
    """A credential survives encode -> parse -> extract unchanged."""
    log = credential_to_log("me@example.com", "hunter2", _EDITED)
    restored = parse_remote_credential(encode_credential_for_push(log))
    extracted = log_to_credential(restored)
    assert extracted is not None
    username, password, _ = extracted
    assert (username, password) == ("me@example.com", "hunter2")


def test_a_blank_credential_contributes_nothing() -> None:
    """An unconfigured device must not push an empty string over a peer's value.

    ``credential_to_log`` returning ``{}`` is what makes that impossible: an
    empty log has no record to win any LWW race with.
    """
    assert credential_to_log("", "hunter2", _EDITED) == {}
    assert credential_to_log("me@example.com", "", _EDITED) == {}
    assert credential_to_log("", "", _EDITED) == {}


def test_an_empty_log_reads_back_as_not_configured() -> None:
    """No credential anywhere is "not configured", not an error."""
    assert log_to_credential({}) is None


def test_a_half_written_record_reads_back_as_not_configured() -> None:
    """A record missing either half is unusable rather than half-applied."""
    hlc = Hlc.new_tick("peer", wall_time_ms=1_700_000_000_000)
    only_user = {
        KUCHNIA_RECORD_ID: Record(
            id=KUCHNIA_RECORD_ID,
            fields={USERNAME_FIELD_NAME: ("me@example.com", hlc)},
        )
    }
    assert log_to_credential(only_user) is None


def test_a_later_edit_wins() -> None:
    """LWW resolves two devices that each set a credential."""
    older = credential_to_log(
        "old@example.com", "old-pass", "2026-08-01T09:00:00+02:00"
    )
    newer = credential_to_log(
        "new@example.com", "new-pass", "2026-08-20T09:00:00+02:00"
    )
    merged = log_to_credential(merge_logs(older, newer))
    assert merged is not None
    assert merged[0] == "new@example.com"
    assert merged[1] == "new-pass"


def test_re_syncing_an_unchanged_credential_is_a_no_op() -> None:
    """Identical input yields an identical clock, so no spurious republish.

    Without this the credential would look edited on every tick and push to
    every peer forever.
    """
    first = credential_to_log("me@example.com", "hunter2", _EDITED)
    second = credential_to_log("me@example.com", "hunter2", _EDITED)
    assert encode_credential_for_push(first) == encode_credential_for_push(second)


def test_an_unparsable_edit_time_loses_to_a_real_one() -> None:
    """A junk timestamp falls back to the epoch rather than winning by accident."""
    junk = credential_to_log("junk@example.com", "junk-pass", "not-a-timestamp")
    real = credential_to_log("real@example.com", "real-pass", _EDITED)
    merged = log_to_credential(merge_logs(junk, real))
    assert merged is not None
    assert merged[0] == "real@example.com"


def test_a_device_that_predates_this_document_relays_it() -> None:
    """The canary: an unknown field is merged in and pushed straight back out.

    ``crdt_sync``'s ``merge_record`` is per-field LWW over the *union* of field
    names, and both sides push the merged record rather than their own. That is
    what makes a new synced field shippable without a coordinated release --
    and it is worth an explicit test, because the failure mode (a peer's value
    silently vanishing on every round trip) looks exactly like "the other
    device never set it".
    """
    hlc = Hlc.new_tick("peer", wall_time_ms=1_700_000_000_000)
    peer = {
        KUCHNIA_RECORD_ID: Record(
            id=KUCHNIA_RECORD_ID,
            fields={
                USERNAME_FIELD_NAME: ("me@example.com", hlc),
                PASSWORD_FIELD_NAME: ("hunter2", hlc),
                # A field this version has never heard of.
                "future-field": ("from-a-newer-release", hlc),
            },
        )
    }
    ours = credential_to_log("", "", _EDITED)
    merged = merge_logs(ours, peer)

    pushed = json.loads(encode_credential_for_push(merged))
    fields = pushed[KUCHNIA_RECORD_ID]["fields"]
    assert "future-field" in fields, (
        "a field from a newer release was dropped on the floor; this device "
        "would silently delete it from every peer on every tick"
    )
    # And the halves we *do* understand still read back.
    extracted = log_to_credential(merged)
    assert extracted is not None
    assert extracted[1] == "hunter2"


def test_a_blank_half_in_a_merged_record_reads_as_not_configured() -> None:
    """An empty-string password is unusable even when both fields exist."""
    hlc = Hlc.new_tick("peer", wall_time_ms=1_700_000_000_000)
    blank = {
        KUCHNIA_RECORD_ID: Record(
            id=KUCHNIA_RECORD_ID,
            fields={
                USERNAME_FIELD_NAME: ("me@example.com", hlc),
                PASSWORD_FIELD_NAME: ("", hlc),
            },
        )
    }
    assert log_to_credential(blank) is None


def test_a_non_object_payload_is_rejected() -> None:
    """A corrupt push raises rather than being half-applied."""
    with pytest.raises(TypeError, match="not an object"):
        parse_remote_credential("[1, 2]")


def _credential_fixture() -> dict[str, Any]:
    """The shared payload/expected pair, read from the committed JSON."""
    path = (
        Path(__file__).resolve().parents[2] / "tests/fixtures/kuchnia_credential.json"
    )
    with path.open(encoding="utf-8") as handle:
        data: dict[str, Any] = json.load(handle)
        return data


def test_the_shared_credential_fixture_matches() -> None:
    """The Dart adapter asserts these same cases against this same file.

    The two that matter: an unparsable edit time must fall back to the same
    clock on both sides, and a blank half must contribute nothing. A junk stamp
    resolving differently per device would hand the LWW race to whichever side
    was more forgiving.
    """
    fixture = _credential_fixture()
    with patch(
        "diet_guard.sync_merge._kuchnia.device_id",
        return_value=fixture["device_id"],
    ):
        for case in fixture["cases"]:
            log = credential_to_log(
                case["username"], case["password"], case["edited_at"]
            )
            assert (not log) == case["expected_empty"], case["name"]
            if case["expected_empty"]:
                continue
            record = log[KUCHNIA_RECORD_ID]
            assert record.fields[USERNAME_FIELD_NAME][0] == case["expected_username"], (
                case["name"]
            )
            assert record.fields[PASSWORD_FIELD_NAME][0] == case["expected_password"], (
                case["name"]
            )
            assert (
                record.fields[PASSWORD_FIELD_NAME][1].wall_time_ms
                == case["expected_wall_time_ms"]
            ), case["name"]
