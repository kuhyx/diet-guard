#!/usr/bin/env python3
"""Regenerate the shared catering-credential parity fixture.

The fixture (``tests/fixtures/kuchnia_credential.json``) is read by *both*
``diet_guard/tests/test_kuchnia_credential_sync.py`` and
``app/test/sync_merge_kuchnia_test.dart``, for the same reason the menu
fixture is: two suites written independently from the same prose is not a
gate.

What has to agree across the two languages is narrow but sharp:

* an **unparsable** edit time must fall back to the same clock on both sides
  (Python catches ``ValueError`` from ``fromisoformat``; Dart's
  ``DateTime.tryParse`` returns null), because a junk stamp that resolved
  differently per device would hand the race to whichever side was more
  forgiving, and
* a **blank half** must contribute nothing, or a half-filled settings form
  pushes an empty-string password that wins LWW against a real one.

The node id is pinned because it differs per install and is not part of what
parity guarantees; the wall time and the field values are.

Run it from the repo root:

    python3 scripts/build_kuchnia_credential_fixture.py
"""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

from diet_guard.sync_merge._kuchnia import credential_to_log

FIXTURE = (
    Path(__file__).resolve().parent.parent / "tests/fixtures/kuchnia_credential.json"
)

#: Stands in for the per-install uuid, which is not part of the parity claim.
_DEVICE_ID = "fixturedev"

_CASES: list[dict[str, object]] = [
    {
        "name": "a normal credential",
        "username": "me@example.com",
        "password": "hunter2",
        "edited_at": "2026-08-23T10:00:00+02:00",
    },
    {
        "name": "an unparsable edit time falls back to the epoch",
        "username": "me@example.com",
        "password": "hunter2",
        "edited_at": "not-a-timestamp",
    },
    {
        "name": "a blank password contributes nothing",
        "username": "me@example.com",
        "password": "",
        "edited_at": "2026-08-23T10:00:00+02:00",
    },
    {
        "name": "a blank username contributes nothing",
        "username": "",
        "password": "hunter2",
        "edited_at": "2026-08-23T10:00:00+02:00",
    },
]


def build() -> dict[str, object]:
    """Return the fixture: each case with the result Python produces."""
    cases = []
    with patch(
        "diet_guard.sync_merge._kuchnia.device_id",
        return_value=_DEVICE_ID,
    ):
        for case in _CASES:
            entry = dict(case)
            log = credential_to_log(
                str(case["username"]),
                str(case["password"]),
                str(case["edited_at"]),
            )
            entry["expected_empty"] = not log
            if log:
                record = log["kuchnia"]
                entry["expected_wall_time_ms"] = record.fields["password"][
                    1
                ].wall_time_ms
                entry["expected_username"] = record.fields["username"][0]
                entry["expected_password"] = record.fields["password"][0]
            cases.append(entry)
    return {
        "_comment": (
            "Shared parity fixture for the catering credential's sync adapter. "
            "Read by BOTH diet_guard/tests/test_kuchnia_credential_sync.py and "
            "app/test/sync_merge_kuchnia_test.dart. Regenerate with "
            "scripts/build_kuchnia_credential_fixture.py."
        ),
        "device_id": _DEVICE_ID,
        "cases": cases,
    }


def main() -> None:
    """Write the fixture to disk.

    Deliberately silent: ``T201`` bans ``print`` here, and the script's output
    is the file itself -- ``git diff`` is how you check what changed.
    """
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    with FIXTURE.open("w", encoding="utf-8") as handle:
        json.dump(build(), handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


if __name__ == "__main__":
    main()
