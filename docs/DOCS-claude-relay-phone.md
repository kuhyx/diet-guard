# The phone's side of the Claude relay

Code in `app/lib/services/claude_relay_*.dart`; the other half of [the contract](DOCS-claude-relay.md).


`RtdbClaudeRelay` implements the screen's `ClaudeRelayClient`; the wire is
`claude_relay_wire.dart`, gated by the fixture
(`app/test/services/claude_relay_contract_test.dart`). The fixture's
`key_hex` is the cipher key itself, which is what `E2eKey.cipher()` hands out
on both devices; the phone gets it through `openDietGuardCipher`, the same
keystore passphrase and header as the log sync (locked = `SyncLockedException`
= the lock glyph on the sparkle).

- `rid` is a ULID made on the phone (`newRequestId`); the entry id is
  `uuid5(entry_id_namespace, rid)` (`claudeEntryId`), computed before any
  answer. A result whose `entry_id` differs is refused, so undo (a tombstone on
  that id) and the logged row always address the entry the PC wrote.
- The phone PUTs `requests/<rid>/req` with `created = {".sv": "timestamp"}`,
  then lists the node's child keys (shallow: the photo is never re-read) every
  1 s, every 5 s after 30 s. No `claim` within 3 s: queued (hourglass), the
  same stream keeps waiting, up to 15 min. A `result` is opened, the node
  `requests/<rid>` is deleted, and the event is shown.
- Fail closed, visibly (error glyph): a body that breaks section 2 (checked
  first, nothing is sent), a failed PUT, three failed polls in a row, a result
  that does not open or is malformed, an entry id mismatch, the node vanishing.
- **Withdrawing.** A local check-mark log while a request is in flight or queued
  calls `cancel(rid)`: one read with `X-Firebase-ETag`, then a `DELETE` with
  `if-match`. A claim written in between changes the ETag and turns the delete
  into a 412, so "unclaimed" is decided atomically. If it was claimed the PC
  *will* log the meal; that race is accepted. The phone keeps the stream open so
  the second meal still shows as a row with an undo instead of arriving unseen.
