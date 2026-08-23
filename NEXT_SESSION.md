# Next session: put the Kuchnia importer on the phone

Paste the prompt below into a fresh session. Delete this file once it's done.

---

## Prompt

Port the Kuchnia Wikinga catering import to the Flutter app so the phone can
fetch the day's dishes **with the PC completely off**. Today the importer is
Python-only and the phone just receives the banked results through sync.

Read `docs/kuchnia-wikinga.md` first — it has the recovered API map, the traps,
and why each decision went the way it did. `CLAUDE.md`'s "Do NOT" section and
`docs/meal-schedule.md` are the other two load-bearing reads.

State: `main` is clean at `93669776b6d`. Phone (Pixel 6a, `23181JEGR08034`)
has 1.0.55/vc130 installed and verified working; repo is at 1.0.56.

### Decisions already made (do not re-litigate)

The user answered these explicitly on 2026-08-23:

1. **The phone fetches directly.** Not "PC banks on a timer and the phone
   receives it" — it must work when the PC is unavailable. So the HTTP client,
   the parser and the slot spread all get Dart implementations.
2. **The catering password syncs**, so a complete reinstall restores it. The
   user chose this knowing the trade-off. It will be **plaintext in Firebase
   RTDB** — the rest of the synced state is not encrypted either, so do not
   describe it as "encrypted like everything else".
3. That contradicts the current doc rule ("a credential must never leave the
   machine it was entered on"). **Rewrite that paragraph**, don't bolt an
   "Exception:" onto it (`memories/mistakes.md`).
4. `kuchnia_session.json` (the live cookie) stays **device-local**. It is
   regenerable, so syncing it buys nothing and widens exposure.

### Sequence (the first item is a prerequisite, not a follow-up)

1. **Settings field + credential sync.** The phone cannot fetch until the
   password is on it. Sync it as its own record; check `sync_merge/` relays a
   new record type rather than dropping it — it enumerates handlers
   (`_banks`, `_budget`, `_daylog`, `_schedule`), the same fixed-key-set shape
   that would silently drop an unknown field.
2. **Fetch + parse + bank**, read-only. No logging. Verify against the live
   panel on-device.
3. **Wire to the log flow**, keeping the never-log-unattended rule: the phone
   *offers* dishes, the user still taps to log.

### The parity risk stops being theoretical

`_kuchnia_spread.py`'s docstring says the integer-only rule is theoretical
"because the phone has no importer and so no mirror of this code". **This port
creates that mirror — update that docstring in the same commit.** Two things
now have to agree exactly across languages:

- **`i * S // N` → `i * S ~/ N`.** Python's `round` is banker's, Dart's is
  half-away-from-zero. A float path silently desyncs which slot a dish lands
  in, and a slot one device offers while the other does not is a checkpoint
  that can never be satisfied — a permanent lock.
- **`_energy_is_consistent`'s ~1% tolerance**, which *drops* dishes. If the
  two sides disagree about which dishes pass, each re-adds what the other
  dropped, `add_manual_entry` restamps `t` unconditionally, and the curated
  bank republishes to every peer on every refresh.

Gate both with **one shared JSON fixture** committed to the repo, asserted by
`pytest` *and* `flutter test` — same input, same expected dish list, dropped
dishes, slot assignment and bank keys. Two independently-written suites from
the same prose is not a gate.

Also verify a Dart-banked and a Python-banked record for the same dish are
**byte-identical JSON**; float formatting (`435.0` vs `435`) is the likely
divergence and would cause the same rewrite/restamp flood.

### Platform seam

`app/` builds Android + web only; the desktop app *is* the web build in Chrome
(`app/test/repo_invariants_test.dart` enforces this). The catering panel sends
no CORS headers, so a browser cannot call it — **make the feature Android-only
and disabled on web**. `dart:io` does not fail a web compile, it throws at
runtime as a blank white window, so branch on `kIsWeb` *before* any
`Platform.is…`, and keep `dart:io` to `*_io.dart` seams. `package:http` and
`flutter_secure_storage` are already dependencies.

### Constraints

- 250 lines per file (860 Python lines → expect 6+ Dart files).
- 100% branch coverage on the Python side; `flutter test` green.
- `pre-commit run --files <changed>` before finishing.
- Any new Python state path must patch `conftest._isolate_state` in the *same*
  edit, or the suite writes to live user data.
- Never log a delivery unattended — a delivered meal is not an eaten meal.

### Verify on the phone, not just in tests

Mobile is the primary platform (`phone-deploy` skill). Deploy with
`~/.claude/scripts/phone_deploy.sh ~/diet-guard/app --release`, which now runs
a pre-install sync gate (`scripts/sync_freshness.py`, added 2026-08-23) and
picks the build number itself. Never uninstall or `pm clear`.

**The phone is the user's daily driver — do not leave the app mid-flow, and
do not grab focus on their desktop.** (Two complaints on 2026-08-22 about a
test gate window and an emulator stealing the cursor.)

### Done

`python -m diet_guard kuchnia` and the phone's own fetch produce the **same
banked dishes for the same day**, proven by the shared fixture in both suites
and observed once on-device with the PC's importer not run that day.
