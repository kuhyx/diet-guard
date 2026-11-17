"""Where the "send to Claude" relay lives in RTDB and what is sealed.

The contract is ``docs/DOCS-claude-relay.md``; ``tests/fixtures/
claude_relay_contract.json`` pins the same layout for the phone. The root is
chosen so its e2e header is the one diet_guard already uses
(``diet-guard-sync/e2e``): same passphrase, same salt, same key.

Imports ``rtdb_relay`` and ``crdt_sync``, so only the relay worker's own
modules import this one -- never the gate or the CLI at load time.
"""

from __future__ import annotations

from typing import Final

from crdt_sync import E2eLayout
from rtdb_relay.layout import Layout

#: The unencrypted-era prefix the e2e root and header are derived from.
OLD_PREFIX: Final = "diet-guard-sync/claude"
E2E_LAYOUT: Final = E2eLayout.of(OLD_PREFIX)
ROOT: Final = E2E_LAYOUT.prefix

#: The only request kind this relay serves.
KIND: Final = "meal"

LAYOUT: Final = Layout(
    root=ROOT,
    clear=("requests/*/claim",),
    units={
        "requests/*/req": frozenset({"created"}),
        "requests/*/result": frozenset({"at"}),
    },
)
