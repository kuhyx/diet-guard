# CLAUDE.md — diet_guard

## What this does

A log-to-unlock gate: every ~30 minutes, `diet-guard-gate.timer` runs
`diet-guard-gate.service`, which checks whether a meal slot (08:00, 12:00,
16:00, 20:00) has elapsed without a logged meal. If so, it opens a fullscreen
Tk window that blocks the desktop until the user logs what they ate (with
autocomplete from a local food-name "bank", optionally seeded from Open Food
Facts via `requests`). It also tracks a daily calorie/macro budget, sealed at
init time and tamper-resistant via `chattr +i`.

See `docs/design.md` for the original feature spec (meal-slot timing logic,
the Tue/Wed/Thu "filled most of the day" catch-up rule, multi-item meals).

## Scheduling

`diet-guard-gate.timer` — wall-clock `OnCalendar=*-*-* *:00/30:00`,
`Persistent=true`. Deliberately wall-clock rather than boot-relative: an
earlier boot-relative timer interacted badly with fullscreen games grabbing
keyboard/mouse input around the same point in their session, so this is
pinned to the clock instead of "N minutes after boot/login."

`diet-guard-gate.service` is `Type=oneshot`, fires every tick, and exits 0
immediately if no lock is due — cheap enough to run that often. It needs
`DISPLAY`/`XAUTHORITY` because it opens a Tk window; see the inline comments
in the unit file for why `XAUTHORITY` is pinned explicitly (a `Persistent=true`
catch-up run at session start can beat the display manager writing
`~/.Xauthority`) and why a real fix lives in Python (`wait_for_display()`)
rather than in the unit file.

## Cross-device sync

`diet-guard-sync.timer` fires `python -m diet_guard sync` every ~15 minutes
(headless, no `DISPLAY` needed — separate from the gate timer on purpose, see
the unit file's comment for why). It pulls every other device's pushed log
from the private `kuhyx/diet-guard-sync` GitHub repo (used as dumb file
storage via the REST Contents API, not a git clone), merges with the local
log (`_sync_merge.merge_logs`: union by `id`, tombstone wins, legacy
`(time, desc)` dedup for pre-`id` entries), **re-signs every persisted entry**
regardless of origin, rebuilds the food bank, then pushes this device's own
merged log back up.

Re-signing on every merge (not just phone-origin entries) is the
non-negotiable step: `_entry_is_valid()` drops any unsigned entry once a
machine has the shared HMAC key, and the phone never holds that key, so
skipping the re-sign would silently lose every phone-logged meal on the very
next read.

Requires a one-time manual setup `install.sh` does **not** automate: create a
fine-grained GitHub PAT scoped to `diet-guard-sync`'s contents (read/write),
then save it to `~/.config/diet_guard/sync_token`, mode 600. Until that file
exists, every sync tick is a harmless no-op that logs `sync not configured`.

The food bank stays *derived*, never synced: only `food_log.json` round-trips
through GitHub, and each device rebuilds its own `food_bank.json` locally by
replaying the merged log (`_foodbank.rebuild_food_bank`) — this is what avoids
needing CRDT counter-merge logic for a food's `count`.

## Production dependency installation — read this before adding any dependency

`diet-guard-gate.service` runs `/usr/bin/python` directly — **not** a venv.
Any new non-stdlib dependency (this package itself, `gatelock`, `requests`,
anything added later) must be installed into system Python's *user*
site-packages, the same place `python-kasa` already lives:

```bash
/usr/bin/python3 -m pip install --user --break-system-packages -e .
```

`install.sh` already does this. **If you add a dependency and only install it
into a dev venv, the production service will silently fail with
`ModuleNotFoundError` on its next tick** — this exact gap caused a 3-day
diet_guard production outage (2026-06-19 to 2026-06-22) when `gatelock` was
added but only `pip install`-ed into `.venv`. Always verify against
`/usr/bin/python3 -c "import <new_dep>"`, not just the dev venv, before
considering a dependency change done.

**Always run `install.sh` (or `pip install -e`) from a durable clone, not a
scratch directory.** `install.sh` does `pip install -e "$REPO_DIR"` —
editable, so a later `git pull` in that same clone updates the running
production code with no reinstall needed. The clone must live somewhere
permanent (this repo's convention: `~/diet-guard`, mirroring `~/screen-locker`
for the screen-locker package) — if you `pip install -e` from `/tmp/...` or
run `pip install "diet_guard @ git+https://..."` as a one-off, you get a
non-editable snapshot frozen at that commit, and the next `git push` here
silently does **not** reach the running service.

## Operational gotchas

- **The budget file is sealed immutable.** `~/.local/share/diet_guard/.budget`
  gets `chattr +i` after `init` (see `install.sh` step 6). This is the actual
  tamper-resistance mechanism — the budget can't be casually edited to "make
  room" once locked. To intentionally change it: `sudo chattr -i` the file,
  re-run `python -m diet_guard init`, then re-lock.
- **Biometrics are used once and discarded.** `init` asks for biometrics to
  compute the daily budget, then the only persisted output is the computed
  budget number — never the biometrics themselves.
- **State lives entirely under `~/.local/share/diet_guard/`** — no
  cross-repo file coupling (unlike wake_alarm, which reads
  `~/screen-locker/screen_locker/workout_log.json`). Safe to reason about in
  isolation, with one exception: `diet-guard-sync.timer` reads/writes the
  private `kuhyx/diet-guard-sync` GitHub repo (see "Cross-device sync" above)
  and `~/.config/diet_guard/sync_token`.

## Commands

- Run tests: `python -m pytest diet_guard/tests/ --cov=diet_guard --cov-branch --cov-fail-under=100`
- Lint: `pre-commit run --all-files`
- Test the lock manually (safe, closeable): `python -m diet_guard gate --demo`
- Run one sync tick manually: `python -m diet_guard sync`
- Install for production: `bash install.sh`

## Do NOT

- Don't relax the meal-slot/macro logic without re-reading `docs/design.md` —
  the Tue/Wed/Thu catch-up rule and multi-item meal summing are deliberate,
  not accidental complexity.
- Don't add a dependency without doing the production install-path check
  above.
- Don't remove the `chattr +i` step from `install.sh` — it's the actual
  enforcement mechanism, not a formality.
