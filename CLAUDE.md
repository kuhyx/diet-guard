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

## Operational gotchas

- **The budget file is sealed immutable.** `~/.local/share/diet_guard/.budget`
  gets `chattr +i` after `init` (see `install.sh` step 5). This is the actual
  tamper-resistance mechanism — the budget can't be casually edited to "make
  room" once locked. To intentionally change it: `sudo chattr -i` the file,
  re-run `python -m diet_guard init`, then re-lock.
- **Biometrics are used once and discarded.** `init` asks for biometrics to
  compute the daily budget, then the only persisted output is the computed
  budget number — never the biometrics themselves.
- **State lives entirely under `~/.local/share/diet_guard/`** — no
  cross-repo file coupling (unlike wake_alarm, which reads
  `~/screen-locker/screen_locker/workout_log.json`). Safe to reason about in
  isolation.

## Commands

- Run tests: `python -m pytest diet_guard/tests/ --cov=diet_guard --cov-branch --cov-fail-under=100`
- Lint: `pre-commit run --all-files`
- Test the lock manually (safe, closeable): `python -m diet_guard gate --demo`
- Install for production: `bash install.sh`

## Do NOT

- Don't relax the meal-slot/macro logic without re-reading `docs/design.md` —
  the Tue/Wed/Thu catch-up rule and multi-item meal summing are deliberate,
  not accidental complexity.
- Don't add a dependency without doing the production install-path check
  above.
- Don't remove the `chattr +i` step from `install.sh` — it's the actual
  enforcement mechanism, not a formality.
