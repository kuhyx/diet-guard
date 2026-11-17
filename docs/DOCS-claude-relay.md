# The "send to Claude" relay (contract)

The phone sends a food description and/or a photo. A worker on the PC runs
Claude on kuhy's Max subscription, **logs the meal at once (no review)** and
answers the phone. Transport is Firebase RTDB through the shared
`rtdb_relay` package (`kuhyx/utils`, tag `rtdb-relay-v0.1.1`), the same wire
format as the tutor app. No VPN, no open port, only kuhy's Google account.

This file is the contract both halves build against. The fixture
`tests/fixtures/claude_relay_contract.json` is read by the Python tests and
by the phone's Dart tests, so the two cannot drift. Regenerate it with
`scripts/build_claude_relay_fixture.py` (random nonces: bytes change, the
plaintext does not). The worker lives in `diet_guard/_claude_*.py`; the
estimator and its skill are described at the end.

## 1. Where it lives in RTDB

Root `R = diet-guard-sync/claude-e2e`. It is `E2eLayout.of("diet-guard-sync/claude")`,
chosen so its header path is **the existing header `diet-guard-sync/e2e`**,
the one `E2eLayout.of("diet-guard-sync/devices")` already uses. Same
passphrase, same Argon2id salt, same key: the phone unlocks nothing new. A
test asserts the two header paths are equal; a second header would be a
second salt and the phone could not open a request.

| Path under `R` | Writer | Value |
|---|---|---|
| `requests/{rid}/req` | phone | sealed unit, clear sibling `created` |
| `requests/{rid}/claim` | worker | clear `{by, lease_until, attempt, phase, at}` |
| `requests/{rid}/result` | worker | sealed unit, clear sibling `at` |

Every other path is refused by the sealer (fail closed). A sealed unit is
`{"_e2e": <blob>, <clear siblings>}`; the blob is crdt_sync's `E2eCipher`
over compact JSON with the unit's full path (`R/requests/{rid}/req`) as AAD,
so a blob copied to another path does not open. Byte format:
`~/src/utils/rtdb_relay/rtdb_relay/tests/data/e2e_vectors.json`. Both
`req` and `result` are sealed, **the photo included**: no food text or image
is ever in clear.

`rid` is a **ULID** (`[0-9A-HJKMNP-TV-Z]{26}`), not a uuid. `rtdb_relay`
never serves any other key, so a uuid-keyed request would sit unanswered
forever. This is a deliberate deviation from the first sketch ("id (uuid)");
the rid is the request's `id`.

## 2. Request (`requests/{rid}/req`)

Plaintext before sealing:

```json
{"kind": "meal", "dev": "<phone device id>", "sent_at": 1767225600000,
 "body": {"text": "2 jajka sadzone i kromka chleba",
          "photo_jpeg_b64": "<base64>", "client_slot_min": 720, "mode": "due"}}
```

plus the **clear** sibling `created` = `{".sv": "timestamp"}` (RTDB server
time, ms). `created`, not `sent_at`, drives the 24 h rule: a phone clock can
be wrong.

| Field | Rule |
|---|---|
| `kind` | exactly `"meal"`; anything else -> `unknown_kind` |
| `body.text` | optional string, 1..2000 chars after trim |
| `body.photo_jpeg_b64` | optional standard base64 of a JPEG (starts `FFD8`), longest side <= ~1024 px, <= 600 000 base64 chars |
| `body.client_slot_min` | required int 0..1439: the slot the phone would use now (its own `slotForLog`) |
| `body.mode` | required: `"due"` or `"normal"` |

At least one of `text` / `photo_jpeg_b64` is required. An invalid body gets
`bad_request` (below) and nothing is logged. The phone downsizes and
re-encodes the photo before sealing (the raw camera file is several MB).

## 3. Result (`requests/{rid}/result`)

`ok` is authoritative. Every result the meal handler writes also carries
`status` (`"logged"` | `"error"`); the two guard failures `unsealed` and
`unknown_kind` come from `rtdb_relay` before the handler and carry only
`ok: false`, so a client reads `status = ok ? "logged" : "error"`.

Logged (clear sibling `at` = server ms):

```json
{"ok": true, "kind": "meal", "status": "logged", "id": "<rid>",
 "entry_id": "<uuid5 of rid>", "desc": "2 jajka sadzone i kromka chleba",
 "grams": 190, "kcal": 410, "protein_g": 17.5, "carbs_g": 22, "fat_g": 26,
 "slot_min": 720, "time": "2026-11-17T12:03:41+01:00"}
```

Error:

```json
{"ok": false, "kind": "meal", "status": "error", "id": "<rid>",
 "error_code": "estimate_failed", "code": "estimate_failed",
 "error": "model returned no valid JSON", "retry": true}
```

`code` and `error_code` are the same string (`code` is `rtdb_relay`'s name,
`error_code` the phone-facing one). `error` is for the log, never the UI.

| `code` | Meaning | `retry` |
|---|---|---|
| `bad_request` | body fails section 2 | false |
| `expired` | `created` older than 24 h when the PC got to it | false |
| `estimate_timeout` | Claude exceeded 45 s | true |
| `estimate_failed` | Claude errored or the CLI/login is unusable | true |
| `estimate_invalid` | output not JSON / fails the schema / nonsense values | true |
| `unsealed`, `unknown_kind` | `rtdb_relay` guards | false |
| `internal` | a bug in the handler (visible, never a silent drop) | true |

**No answer is not an error.** If the PC cannot sync or the e2e key is
locked (`SyncError`, `E2eLockedError`, wrong or missing passphrase) the
worker writes nothing, leaves the request pending, logs why, and tries
again (section 6). The phone keeps its hourglass.

## 4. The slot

The PC decides; `client_slot_min` is never trusted in due mode. All maths
reuse `_slots.py` and `_gate.due_slots`; this feature changes none of it.

- **`"due"`**: after a narrow `pull_peer_logs()`, the entry's slot is
  `due_slots(now)[0]`, the **oldest** elapsed-but-unlogged slot of today
  (so a phone meal already logged elsewhere is seen). `client_slot_min` is
  ignored.
- **`"due"` with nothing due** (already logged elsewhere, free day, sick
  day, hold, or outside the enforcement window): not an error. Fall back to
  `slot_for_log(now, schedule)`, the rule `ate` uses.
- **`"normal"`**: `nearest_slot(client_slot_min, schedule)`, the existing
  nearest-slot rule, so a request that waited hours for a switched-off PC
  still lands in the slot the phone saw when it was sent.

The entry's `time` is the processing time (`log_meal` forbids the past), and
`source` is `"claude"`. The logged slot is echoed as `slot_min`.

## 5. Order of work and why

```
phone: PUT req ──────────────────────────────────────────────────────────┐
PC:  claim (ETag lease) -> validate -> age check -> already logged? ->    │
     narrow pull_peer_logs -> Claude estimate -> slot -> log_meal ->      │
     PUT result -> DELETE req -> publish_after_log (background)  <────────┘
```

1. **Idempotent by request id, twice over.** The entry id is
   `uuid5(NAMESPACE, rid)`. Before spending a Claude call the worker looks
   for that id in the raw log (tombstones included). Found: it rebuilds the
   result from the entry and logs nothing. So a duplicate SSE event, a lease
   that expired, or a crash between `log_meal` and the result PUT (the
   worker takes over its own dead claim on restart) all end in one entry.
2. **Pull before Claude.** `pull_peer_logs()` (the narrow one, ~84 ms) fails
   closed. A failure means "do nothing" (section 3) before any model cost.
3. **Answer first, publish last.** `publish_after_log` is a full sync tick
   (15 to 27 s). Run before the answer it would break the 30 s target, so
   the order is log, result, delete `req`, then publish. The result already
   carries everything the phone shows; the entry itself reaches the phone's
   log through the normal sync a moment later. A failed publish is only
   logged: the entry is durable locally and the next tick or lock carries it.
4. **Delete only `req`.** The photo is the heavy part and is useless after
   the answer. `claim` and `result` stay so a phone that was offline when
   the result landed still reads it. The phone should delete
   `requests/{rid}` once it has shown the answer; the worker deletes any
   answered node whose `result.at` is older than 24 h.
5. **Expiry.** A request whose `created` is older than 24 h when the worker
   reaches it gets `expired` and nothing is logged; its `req` is deleted
   like any other.
6. **Blocking work** (log file, sync, Claude) never runs on the event loop.
   One lock serialises "resolve slot + `log_meal`" so two requests do not
   take the same due slot.

## 6. The worker

`python -m diet_guard claude-worker`, run by `diet-guard-claude.service`
(systemd `--user`, `Restart=on-failure`, `WantedBy=default.target`).

- Event-driven: one SSE stream on `R/requests`. Reconnects forever with
  1/2/5/10/30 s backoff; `auth_revoked` reconnects at once; `cancel` (the
  rules now refuse the path) is fatal. Each reconnect begins with the whole
  node, so requests that arrived while the PC was off are served in order.
- Waits are only for faults: the e2e unlock and a failed pre-pull retry
  every 60 s / 30 s while something is pending. No idle timer.
- Session: its own Firebase app name `diet_guard_claude`
  (`~/.config/diet_guard_claude/firebase_auth.json`), never the gate's
  `diet_guard` file (two processes refreshing one token file corrupt it).
  Seed once, see "Deploy". The database URL and API key come from
  `~/.config/crdt-sync/firebase.json`; the passphrase from
  `~/.config/crdt-sync/password`.
- One worker per PC. Claim leases last 300 s and renew every 60 s.
- Dependencies (`rtdb_relay`, `httpx`, `claude_agent_sdk`) are imported only
  inside the worker's own modules, never by the gate or the CLI at load
  time. System Python needs them before the unit starts (see "Deploy").

## 7. Security rules

`~/src/utils/firebase/database.rules.json` pins the **whole database** to
kuhy's uid (`.read` and `.write` on the root: `auth != null && auth.uid ===
<uid>`). `R` is a path inside that database, so **the existing rules already
cover it and no rules change is needed**. The tutor already runs under the
same rule at `tutor/v1-e2e`. The local rendered copy
(`~/.config/crdt-sync/database.rules.json`) matches that shape; the live
console copy could not be read without a signed-in uid (check with an
unauthenticated `curl "$DATABASE_URL/.json"`: must answer
`Permission denied`). A stranger who signs up with the public API key reads
and writes nothing. The worker's session must be kuhy's own account.

## 8. The estimator and its skill

`diet_guard/_claude_estimate.py` exposes the pure function
`estimate_meal(text: str | None, photo: bytes | None) -> Estimate` (also for
the Tk gate later). It runs Claude through `claude_agent_sdk` with an
**isolated `CLAUDE_CONFIG_DIR`** holding only a copy of the OAuth access
token (no refresh token) and `skills/diet-food/SKILL.md`. kuhy's own
`~/.claude` is never read except to copy the token: its hooks would make the
model answer with a grilling round.

- Input: the text, the photo as an image content block, and the closest
  rows of the curated and derived food banks (`search_foods(text)`; for a
  photo-only request the top rows by count).
- Output: strict JSON, enforced by `output_format` json_schema and
  re-validated: `desc`, `grams` (>0), `kcal`, `protein_g`, `carbs_g`,
  `fat_g` (all finite, >= 0, kcal <= 5000), optional `components`. Anything
  else is `estimate_invalid`.
- Failure, timeout, invalid JSON or a missing login: an error result and
  **nothing is logged** (fail closed).

## 9. Deploy (not done by the implementation)

1. `/usr/bin/python3 -m pip install --user --break-system-packages -e .`
   from `~/src/diet-guard` (new deps: `claude-agent-sdk`, `rtdb-relay`,
   `httpx`); verify `/usr/bin/python3 -c "import claude_agent_sdk, rtdb_relay, httpx"`.
2. Seed the worker's session once (one Google consent):
   `python3 -m tool.seed_session --client-id ... --client-secret ... --app diet_guard_claude`
   in `~/src/utils/crdt-sync`.
3. `bash install.sh` (copies and enables `diet-guard-claude.service` once
   the session file exists).
4. Phone side: the sender, hourglass state and result screen. They follow
   sections 1 to 3 and the fixture.
