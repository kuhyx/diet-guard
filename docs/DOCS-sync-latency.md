# Sync latency: what must never block the user

Measured 2026-08-21 against the live remote. Before this work the gate ran a
*full* sync tick before deciding whether to lock: ~27s, and the lock screen's
"Fetch from sync" button ran the same tick inline on the Tk thread.

| Path | Before | After |
|---|---|---|
| `gate --check` (nothing due) | 216ms | ~105ms |
| "Fetch from sync" button | 18-27s | ~84ms |
| `diet-guard log ...` | 15.5s | ~2ms |
| Background full tick | ~27s | ~8.9s |

## The narrow pull

`_sync_refresh.pull_peer_logs()` answers one question — *"has a peer already
logged this slot?"* — and only the peer **logs** can answer it. No budget, no
food banks, no `rebuild_food_bank`, and **no push**.

Three state invariants, each with a regression test, because each is silent
when broken:

* **`pushed_rev` survives verbatim.** This pass never pushes; overwriting it
  convinces the next full tick it has already published, and the device goes
  invisible to every peer, permanently.
* **`peer_revs` is merged, not replaced.** Only changed peers are visited, so a
  wholesale replace drops every untouched entry and re-downloads them next tick.
* **The log is written before the state.** The other order records a peer as
  merged while its records are absent — silent data loss.

Peer enumeration deliberately avoids `list_directory` (~445ms mirrored, because
the GitHub half alone is ~360ms) and unions the revision map with `peer_revs`
instead. Membership is tested with `in`, never `.get(...) is not None`:
`peer_revs` legitimately holds explicit nulls, and treating those as "never
seen" re-downloads them forever.

## Threading

The fetch button runs the pull on a **daemon** worker and marshals the result
back through a `queue.Queue` polled by `root.after`. The worker touches **no
widget** — Tcl is not thread-safe, and that includes `after`. Polling also
makes the completion path testable with no thread at all: put a result on the
queue, call the poll, assert.

A second click while a fetch is in flight is ignored. That is the reentrancy
guard *and* the write-race fix: the pull persists its merge, so two workers
would race two `write_raw_log` calls and orphan one result.

`diet-guard log` publishes through `publish_after_log_detached` (non-daemon, so
the process waits for the push at exit while the user already has their
output). **The gate does not**: `diet-guard-gate.service` is `Type=oneshot`, so
systemd reaps the unit the moment the main thread exits and a background push
would be killed halfway.

## Timeouts

`INTERACTIVE_TIMEOUT_SECONDS` (2s) bounds anything a user waits on.
`SYNC_TIMEOUT_SECONDS` (10s) only ever reached GitHub: `firebase_client_for`
accepts no timeout in crdt_sync v0.6.0, so Firebase silently used its 15s
default and one hung session refresh stalled the lock window. The journal
recorded five such failures in five days, one of them a meal that logged
locally and never published.

`_apply_timeout` reaches for the private `_timeout_seconds` because the pinned
library exposes no other lever. The clean fix is a `timeout_seconds` kwarg
upstream; that is a cross-repo change (five consumers, tag bump).

## Stale peers

Every install mints a uuid and pushes under it, and nothing cleaned them up.
This remote reached 25 devices. Each dead one cost a round trip in the log pull
and in each of the three bank syncs — roughly 400ms per peer per tick.

They were not phone reinstalls: seventeen were frozen at the *same* instant
(2026-08-13T16:45:04) holding near-identical ~400-record copies of one log,
the signature of repeated fresh-install runs. 20 were pruned on 2026-08-21
after verifying zero records would be lost.

`prune-peers` is dry-run by default, refuses `--apply` without `--backup-dir`,
and never proposes `pc`/`phone`/`desktop` (they carry pre-migration history and
`SYNC_LEGACY_DEVICE_ID` names one as this device's own former path).

**It must delete each device's `revs/` marker along with its data.**
`_candidate_peers` enumerates peers from that map rather than from
`list_directory`, so an orphaned marker resurrects a deleted device as a
candidate and buys a round trip discovering it is gone. Pruning without this
took the narrow pull from ~90ms to ~15s — slower than before the prune.

## Import cost

`gate --check` used to import `requests` (~78ms) and tkinter for a window it
never opens. Both are now resolved through module-level `__getattr__`
(PEP 562) plus `import_module`, which keeps every existing `patch.object`
target working and needs no lint suppression. The chains were
`_cli_args` -> `_cli_sync` -> `crdt_sync` -> `requests`, and
`_cli_log` -> `_resolve` -> `_estimator_off` -> `requests`.

Verify with `python -X importtime -c "import diet_guard._cli_gate" | grep -c requests` (expect 0).
