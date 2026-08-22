# CLAUDE.md — diet_guard

A log-to-unlock gate. Every ~30 min `diet-guard-gate.timer` checks whether a
meal slot (08:00, 12:00, 16:00, 20:00 by default — the schedule is
user-configurable, see below) elapsed unlogged; if so it opens a
fullscreen Tk window that blocks the desktop until the user logs what they
ate. It also tracks a daily calorie/macro budget, seeded from biometrics at
`init` and freely editable afterward on either device. A History tab
(`_gatelock_calendar.py`) and the phone's Calendar screen show adherence,
streaks, a YTD tally and weekly/monthly averages, all derived from
`_daystatus.py` / `day_status_service.dart` and `_averages.py` /
`average_service.dart`.

`docs/design.md` holds the original spec (slot timing, the Tue/Wed/Thu
catch-up rule).

## Commands

- Tests: `python -m pytest diet_guard/tests/ --cov=diet_guard --cov-branch --cov-fail-under=100`
- Lint: `pre-commit run --all-files`
- Test the lock (safe, closeable): `python -m diet_guard gate --demo`
- One sync tick: `python -m diet_guard sync`
- Averages: `python -m diet_guard averages`
- Prune dead sync peers (dry run): `python -m diet_guard prune-peers`
- Install for production: `bash install.sh`
- App tests: `cd app && flutter test`
- Desktop app: `cd app && bash run.sh`
- Install desktop app: `cd app && bash install_arch.sh`
- Phone build: `cd app && flutter build apk --release`

## Scheduling

`diet-guard-gate.timer` is wall-clock (`OnCalendar=*-*-* *:00/30:00`,
`Persistent=true`), not boot-relative — a boot-relative timer collided with
fullscreen games grabbing input. `diet-guard-gate.service` is `Type=oneshot`
and exits 0 immediately when no lock is due. It needs `DISPLAY`/`XAUTHORITY`;
see the unit file's comments and `wait_for_display()`.

## Cross-device sync

A sync tick pulls every other device's log from `kuhyx/syncs`
(`diet-guard-sync/`, dumb file storage via the REST Contents API), merges
(`_sync_merge.merge_logs`: union by `id`, tombstone wins, legacy
`(time, desc)` dedup), **re-signs every persisted entry**, rebuilds the food
bank, pushes back.

**On the PC, sync is event-driven — there is no periodic timer.** The old
`diet-guard-sync.timer` (~15 min) was deleted: it paid a network round-trip on
every idle tick to approximate the two moments state actually changes here.

- **Before a lock** — `_cli_gate._should_lock` runs the cheap local
  `gate_is_due()` first and pulls *only* when a lock is otherwise due, so a
  meal just logged on the phone clears the lock and a not-due tick never
  touches the network. That pull is the **narrow** one
  (`_sync_refresh.pull_peer_logs`): peer logs only — no budget, no banks, no
  push. Only they answer "has a peer logged this slot?". ~84ms vs ~27s for a
  full tick, which must never sit in front of a fullscreen lock.
- **After a meal is logged** — `_sync_events.publish_after_log`, called from
  all three write paths (`_cli`, `_cli_gate`, `_mcp`). This is what stops the
  *phone* nagging for a slot already logged on the PC.
- The gate's publish lives in `cmd_gate` **after `MealGate.run()` returns**,
  never in the unlock handler: that runs on the Tk thread with the window up,
  so a hanging call would keep the user locked in behind a successful log. It
  also covers the "Synced from another device" unlock.
- Accepted trade: a PC that is on but neither logging nor locking does not
  pull, so an inbound phone edit lands at the next log or lock. Bounded by slot
  spacing — an unlogged day raises a lock.
- **`gate --demo` publishes too** (the call sits after the `finally`). "Safe,
  closeable" means it cannot trap you at the keyboard, not that it is offline:
  demo already writes real entries through `log_meal` (only the *slot* is
  synthetic).
- `pull_shared_log()` is misnamed: it runs a *full* tick (pull, merge, re-sign,
  persist, **push**, plus budget and both food banks), not just a pull. Use
  `_sync_refresh.pull_peer_logs()` for anything a user waits on.
- **Interactive paths must not block, and stale peers cost real time.** The
  threading rules, the interactive timeout, and `prune-peers` (including the
  `revs/` marker trap that made pruning *slower*) are in
  [docs/sync-latency.md](docs/sync-latency.md) — read it before touching
  `_sync_refresh.py`, the fetch button, or the publish paths.
- Every test that logs a meal would otherwise hit the network through these new
  call sites; `conftest._isolate_state` patches each one
  (`_cli_log.publish_after_log_detached`, `_cli_gate.publish_after_log`,
  `_mcp.publish_after_log`, `_cli_gate.pull_peer_logs`) — not on
  `_sync_events`, so a direct test still exercises the real helper. A new
  network entry point missing from that list reaches the real remote.

- **Re-sign on every merge, not just phone-origin entries.** `_entry_is_valid()`
  drops unsigned entries once a machine has the HMAC key, and the phone never
  holds that key — skipping the re-sign loses every phone-logged meal on the
  next read.
- **The phone's periodic tick syncs unconditionally.** Do not re-gate it on
  `due.isNotEmpty` (`due_slot_check.dart`); logging promptly means nothing is
  ever due, so the phone never publishes and the PC nags for logged slots.
  Publish first, then compute due slots from the merged result.
- **WorkManager background isolates must call `initSyncDeviceId()` themselves.**
  A fresh isolate has its own static state; without it `currentSyncDeviceId`
  falls back to the compile-time role constant and publishes to
  `devices/phone/`. Guarded by `background_sync_service_test.dart`.
- **Catch `RemoteSyncError`, never `GitHubSyncError`.** `FirebaseSyncError`/
  `FirebaseAuthError` are siblings, not subclasses. `ConfigError` subclasses
  `Exception` directly and is covered by neither — `_client_for_run` translates
  it to `SyncError`.
- Needs **one** backend, not both: `~/.config/crdt-sync/` (Firebase, primary)
  or a PAT at `~/.config/diet_guard/sync_token`, mode 600. Neither → the tick
  logs `sync not configured` and no-ops.
- **Both halves of the food bank sync.** The derived bank (`food_bank.json`)
  merges by **`count`** (max-count-wins, idempotent — the right merge for a
  derived counter). The curated bank (`food_bank_manual.json`) is one CRDT
  record per normalized name, LWW by `editedAt`.

## Production dependency installation

`diet-guard-gate.service` runs `/usr/bin/python`, **not** a venv. Any new
non-stdlib dependency must go into system Python's user site-packages:

```bash
/usr/bin/python3 -m pip install --user --break-system-packages -e .
```

Verify against `/usr/bin/python3 -c "import <dep>"`, not the dev venv.
Installing only into `.venv` caused a 3-day production outage (2026-06-19).

Run `install.sh` from a **durable** clone (`~/diet-guard`), never a scratch
dir — it does `pip install -e`, so the clone must persist for `git pull` to
reach the running service.

## Operational gotchas

- **The budget is a plain, freely-editable synced file.** No seal, no signing —
  this deliberately replaced a `chattr +i` mechanism so the value is editable
  from either device. Do not reintroduce the seal as a "fix"; the removal is
  the feature. Every write stamps an edit timestamp; `budget.json` resolves
  concurrent edits LWW.
- **Past days are judged against the budget that applied then.**
  `_budget_history.py` / `budget_schedule.dart` is a forward-only list of
  `(effective_from, kcal)`. `write_budget` / `saveDailyKcalGoal` must seed the
  pre-write value to `1970-01-01` **before** recording today's — reversing that
  makes every past day adopt the new budget. Covered by
  `test_budget_history.py`; it syncs as `hist:<YYYY-MM-DD>` fields on the
  existing `budget` record, so devices predating the feature relay them
  untouched.
- **Biometrics are used once and discarded** — only the computed budget is
  persisted.
- **PC and phone share one source of truth for everything**: food log, budget,
  budget history, body weight (`w`), curated food bank. If you add a stored
  field, sync it or comment why it physically cannot be.
- **State lives entirely under `~/.local/share/diet_guard/`** — no cross-repo
  file coupling. Exception: the sync timer touches `kuhyx/syncs` and
  `~/.config/diet_guard/sync_token`.
- **Every device pushes under a persisted per-install uuid**, not a role
  constant. `_device.py` / `sync_device_id.dart` (`crdt.nodeId`). The old role
  constant survives as the legacy id so `devices/<legacy>/` is skipped as this
  device's own — dropping it makes every tick re-merge our own pre-migration
  log. The app resolves it asynchronously in `main.dart` before
  `LogStorageService.init()`; don't move that call later. Tests must redirect
  `_device.SYNC_DEVICE_ID_FILE` (conftest does).

## The companion app's desktop target is a web build

`app/` builds for **Android** and **web** only. There is no `app/linux/` —
Flutter's GTK embedder manages ~20fps at 3840x2160 where the same Dart in
Chrome sustains ~144fps (`~/todo/docs/desktop-performance-findings.md`). The
desktop app is the web build served by `bin/diet_guard_desktop.dart` in a
Chrome `--app` window.

Enforced by `app/test/repo_invariants_test.dart`: no `app/linux/`, `dart:io`
only in `*_io.dart` seams and `lib/desktop/`, port 8732 and the
`diet-guard-desktop` Chrome profile pinned (IndexedDB is keyed by origin, so
changing either hides the entire local food log).

- Branch on `kIsWeb` *before* any `Platform.is…`, which itself throws on web.
  `dart:io` does not fail a web compile — it throws at runtime, so the symptom
  is a blank white window, not a build error.
- The wrapper holds the GitHub token, not the browser, and proxies
  `api.github.com` plus the CORS-less device flow (`lib/desktop/github_proxy.dart`).
- Desktop reminders only exist while the window is open; the PC's real backstop
  is `diet-guard-gate.timer`.
- Never run `flutter create --platforms linux` in `app/`.

## The meal schedule

The slot hours are user-configurable: a first meal, a last meal, and how
many meals fall between them, evenly divided. Default `(8, 20, 4)` is the
old hardcoded 08/12/16/20. Four load-bearing rules (integer-only
arithmetic, whole-hour slots, the count clamp, the `last + 2h` cutoff), the
forward-only history, and the two edit surfaces are documented in
[docs/meal-schedule.md](docs/meal-schedule.md) — read it before touching
`_slots.py` / `slot.dart`.

## Averages (`_averages.py` / `average_service.dart`)

Three load-bearing rules; changing any silently changes what "under budget"
means:

- **Denominator is logged days, not elapsed days.** An unlogged day is not a
  zero-kcal day.
- **The yardstick is the mean of the per-day budgets over those same logged
  days**, resolved through `BudgetSchedule` — never `daily_budget()`.
- **Today is excluded**; every period ends at `last_complete_day()`. "This
  week" is empty on a Monday, and reports `no logged days yet` rather than a
  fake average.

Band boundaries reuse `_daystatus.OVER_BUDGET_YELLOW_CEILING` /
`kOverBudgetYellowCeiling` **by import, not by copy**. The MCP `get_averages`
tool drops `avg_budget` (budget secrecy on the network only); the CLI, gate and
phone show both.

## Do NOT

- Don't relax the meal-slot logic without re-reading `docs/design.md`. The
  off-hours clamp in `slot_for_log`/`slotForLog` (before the first slot → the
  first slot, after the enforcement window → the last slot) must stay
  byte-identical across Python and Dart; do NOT widen `elapsed_slots`, which
  would make every slot fall due at the end of the day.
- Don't reintroduce floating point into the slot derivation. Python's `round`
  is banker's (`round(2.5) == 2`), Dart's is half-away-from-zero
  (`2.5.round() == 3`), so a float path silently desyncs the two devices —
  and a slot one device offers while the other does not is a checkpoint that
  can never be satisfied, i.e. a permanent lock. Integer `//` and `~/` only.
- Don't re-add the meal builder, "repeat last meal", the reward prompt, or
  **meal photos** — all removed deliberately, enforced by
  `app/test/repo_invariants_test.dart`. Photos also took `image_picker`, the
  blob stores, the `/blobs/` route and the `CAMERA` permission; re-adding them
  means syncing image blobs too.
- Don't strip the `components` field: nothing writes it, but historical
  composite entries and the food bank read it, and it is part of the sync wire
  format.
- Don't let the catering import write a log entry unattended: a delivered
  meal is not an eaten meal, and the gate would satisfy its own checkpoint.
  See [docs/kuchnia-wikinga.md](docs/kuchnia-wikinga.md).
- Don't add a dependency without the production install-path check above.
- Don't reintroduce a seal/`chattr +i` on the budget file.
- Don't re-add a Linux embedder target, and don't change the wrapper's port or
  Chrome profile path.
- Don't exceed **250 lines** in any file. Enforced by the `file-length`
  pre-commit hook and `.github/workflows/file-length.yml`; the cap and its
  exemptions live in `~/utils/file_length/config.py`.

## Flutter/Dart AI rules

_Vendored from [flutter/flutter docs/rules/rules.md](https://github.com/flutter/flutter/blob/main/docs/rules/rules.md)
via `~/.claude/CLAUDE.md` Flutter AI tooling setup. Re-fetch periodically.
Split across five files to stay under the 250-line cap._

- [Language, style and architecture](docs/flutter-rules-language.md)
- [Architecture, lint rules, state and data](docs/flutter-rules-state-and-data.md)
- [Code generation, testing and theming](docs/flutter-rules-testing-and-assets.md)
- [UI: theming, layout and overlays](docs/flutter-rules-ui.md)
- [Colour, type, documentation and accessibility](docs/flutter-rules-design.md)
