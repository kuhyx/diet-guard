# Next session: Kuchnia Wikinga import — verify on real surfaces, then the phone

Paste the prompt below into a fresh session. Delete this file once it's done.

---

## Prompt

The Kuchnia Wikinga catering import landed in `diet-guard` (commit
`26f17700901`, on `main`). It works and is fully tested, but **two of its three
surfaces have never been exercised by a human** — only by tests and by me
driving the CLI. Verify those, then decide about the phone.

Read `docs/kuchnia-wikinga.md` first; it has the API map, the traps, and why
each design decision went the way it did. `AGENTS.md` has a one-line pointer
under "Do NOT".

### What exists

- `python -m diet_guard kuchnia [--log] [--yes]` — banks the day's dishes,
  prints them; logs only with `--log` (which asks first unless `--yes`).
  **Verified working against the live panel**, including on a rerun.
- The lock screen's **"🍱 Today's delivery"** button, beside "Fetch from sync".
  Prefills the meal form dish by dish; the user still clicks "Log & Continue".
  **Never seen in a real window** — only unit-tested with a fake controller.
- An **autoload** when the gate window opens (`MealGate.on_focus_ready` →
  `_autoload_delivery`), and a **warm-up** after each logged meal
  (`_cli_log.cmd_ate`, on the existing background thread). Both guarded to one
  fetch per day by `refresh_delivery_once`. **Neither observed live.**

Credentials are already set up at `~/.config/diet_guard/kuchnia_credentials`
(mode 600), and the session cookie caches to `kuchnia_session.json`.

### Task 1 — see the gate button work (the main thing)

`python -m diet_guard gate --demo` will *not* do it: demo mode deliberately
refuses the catering button, so a synthetic window can never satisfy a real
checkpoint or send real credentials.

So you need a real lock. Options, in order of preference:

1. Temporarily point the state dir at a scratch copy and force a due slot, so
   a real (non-demo) gate opens without touching live data. **Do not smoke-test
   against `~/.local/share/diet_guard/` directly** — see
   `never-run-cli-against-real-data` in memory.
2. Failing that, ask kuhy to trigger it and report what he sees.

Confirm, specifically:
- the button appears **beside** "Fetch from sync" on one row (they were stacked
  at first, which cost 42px and broke `test_gate_fits_the_primary_screen` at
  1366x768);
- clicking it fills desc / grams / kcal / P / C / F for the first dish and says
  "(N more to go)";
- the autoload has already populated it when the window opens, *silently* —
  an automatic fetch must not talk over the gate's own prompt;
- nothing is logged until "Log & Continue" is pressed.

Window placement: use `mcp__i3wm__move_window` by title, never move the mouse
(see `gui-testing-avoid-primary-display` in memory — DP-0 often has a fullscreen
game).

### Task 2 — confirm the after-log warm-up

Log a meal via `python -m diet_guard ate ...` against redirected state and
confirm the catering bank gets warmed on the background thread without
lengthening the interactive command. The guard means it fetches at most once
per day, so clear `~/.config/diet_guard/kuchnia_last_import` to force it.

### Task 3 — decide about the phone

The plan concluded the Flutter app needs **no changes**: it receives the curated
bank and the log through existing sync, and the PC is the only device with
catering credentials.

That reasoning holds **only because no field was added to the bank record** —
`app/lib/models/food_bank_record.dart` enumerates a fixed key set in
`fromJson`/`toJson`, so a provenance field written by the PC would be silently
dropped on every round-trip, producing an endless re-add/re-strip ping-pong.

Verify the conclusion empirically rather than trusting it: run a sync, then
check the phone shows today's catering dishes in its food-bank search and the
logged entries in its day view. If they do, close this out. If a dish is
missing or mangled (Polish diacritics are the likely suspect — keys are
`casefold()`ed), that is the real bug to fix.

Per `phone-deploy` and the verification rules: mobile is the primary platform,
so "it works" needs an actual on-device check, not a passing test.

### Things not to undo

- **Never log a delivery unattended.** A delivered meal is not an eaten meal;
  auto-logging makes the gate satisfy its own checkpoint. This was an explicit
  user decision.
- **`bank_dishes` must keep comparing before writing.** `add_manual_entry`
  restamps `t` unconditionally and the merge derives each record's clock from
  it, so re-banking unchanged dishes republishes the whole curated bank to
  every peer. Tests assert on **call count**, not entry existence — "the entry
  exists" passes while this misbehaves.
- **Don't add a class to the gate's controller chain.** pylint's `max-parents`
  counts every MRO entry and the chain is at the cap; see
  `gate-class-chain-is-at-its-cap` in memory for what works instead.
- **Don't move the gate refresh into `_cli_gate._should_lock`.** `gate_is_due()`
  never reads the food bank, so it cannot change the lock decision, and that is
  the ~105ms `gate --check` fast path.

### Known loose end

`scripts/probe_kuchnia*.py` (four files) were the exploration tools that
recovered the API. They are committed and lint-clean, and
`docs/kuchnia-wikinga.md` explains how to re-run them if the panel changes.
Ask kuhy whether he wants them kept or deleted now the API is understood.
