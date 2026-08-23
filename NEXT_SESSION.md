# Next session: fix the phone's catering prefill, add the one-tap button

Paste the prompt below into a fresh session. Delete this file once it's done.

---

## Prompt

Two bugs in the phone-side Kuchnia Wikinga import that shipped on 2026-08-23
(commits `24be05b9c38`..`d9b3d57900f`). Read
`docs/kuchnia-wikinga-phone.md` and `docs/kuchnia-wikinga.md` first.

State: `main` is clean and pushed. Phone (Pixel 6a, `23181JEGR08034`) has the
build with both bugs installed. 1040 Python tests at 100% branch coverage,
695 Dart tests — all green, which is exactly the problem: **both bugs pass the
entire suite.**

### Bug 1 — a prefilled dish logs ~2.6x its real calories (data corruption, fix first)

Reproduced on the user's real phone on 2026-08-23:

| | |
|---|---|
| bank record | `472.0 kcal`, `25.89 P`, `52.95 C`, `16.62 F`, `258.0 g` |
| what got logged | `1217.8 kcal`, `66.8 P`, `136.6 C`, `42.9 F`, `258.0 g` |
| ratio | `1217.8 / 472.0` = **2.58** = `258 g / 100` |

Entry: `Pieczona owsianka daktylowo-czekoladowa, sos gruszkowy, orzechy włoskie`
at `2026-08-23T08:00:09+02:00`, `source: "kuchnia wikinga"`, slot 8.

**Root cause** (confirmed, don't re-derive): `fillControllersFromDish` in
`app/lib/screens/log_meal_kuchnia_mixin.dart` sets `desc`, the four macros and
`macros.grams` — but **never clears `macros.perGrams`**. `nutritionForPortion`
(`app/lib/models/nutrition.dart:87`) does
`referenceGrams = perGrams > 0 ? perGrams : ateGrams`, so a stale `100` left in
the per-grams field from a previous food-bank pick makes it treat the dish's
*per-portion* macros as *per-100 g* and rescale them by `258/100`.

The PC does not have this bug because `_gatelock_delivery.py:154` calls
`self._clear_inputs()` before filling. The Dart mirror dropped that step.

Required:

- Clear **every** macro field (including `perGrams`) before filling, the same
  way the PC does. Prefer making `fillControllersFromDish` unable to leave a
  stale field rather than adding a `perGrams.clear()` line that the next field
  can forget again.
- A test that would have caught it: pre-seed `perGrams` with `100`, prefill a
  dish, and assert the *computed* `Nutrition` equals the dish's own macros —
  not just that the text fields look right. The current
  `log_meal_kuchnia_mixin_test.dart` asserts controller **text** and passes
  with this bug present; that is why it shipped.
- Check the same class of bug in the settings-button path and anywhere else a
  dish reaches the form.

**Also fix the already-corrupted entry.** One real log entry is wrong by
~746 kcal on 2026-08-23. It is synced, so correcting it locally and letting the
merge carry the fix is the right move — but confirm with the user before
editing their food log, and do not hand-edit `food_log.json` while the app or
a sync tick might write it.

### Bug 2 — the phone has no one-tap "add today's delivery" button

The PC's lock screen has a "🍱 Today's delivery" button that walks the whole
delivery dish by dish (`_gatelock_delivery.py`). On the phone the queue exists
and works (`KuchniaQueueService`, `LogMealKuchniaMixin`), but the **only** ways
to trigger it are the log screen's `initState` and the Settings "Fetch today's
delivery" button — there is no visible control on the log screen itself.

So when the user is standing in the kitchen, there is nothing to tap.

Required:

- A visible control on the log screen that loads today's delivery and prefills
  the first dish, matching the PC's affordance.
- It must show the queue state — the PC's `"(N more to go)"`. The mixin already
  exposes `queueStatusLine` and `dishesStillQueued`.
- Respect the guard split documented in `docs/kuchnia-wikinga.md`'s Triggers
  table: an **explicit** user tap goes and looks (unguarded, like the CLI and
  the settings button); the automatic `initState` load stays guarded by
  `KuchniaQueueService.refreshOnce`.
- `app/lib/screens/log_meal_screen.dart` is at **exactly 249/250 lines**. The
  button will not fit there — put it in a widget of its own, as
  `settings_kuchnia.dart` does.

### Constraints

- 250 lines per file (`file-length` hook). `AGENTS.md` is at exactly 250.
- 100% Python branch coverage; `flutter test` green.
- `pre-commit run --files <changed>` before finishing. The repo bans `noqa`
  outright — there is a `no-noqa` hook, so a suppression is not an escape
  hatch.
- Any new Python state path must patch `conftest._isolate_state` in the *same*
  edit, or the suite writes to live user data.
- Never log a delivery unattended — a delivered meal is not an eaten meal.
- Don't break the cross-language parity gate (`tests/fixtures/kuchnia_day.json`,
  asserted by both suites). If you change `dishFieldValues` or the banked
  record, regenerate with `scripts/build_kuchnia_fixture.py` and **re-read the
  diff** — the script blesses whatever Python currently does.

### Verify on the phone, not just in tests

Mobile is the primary platform. Deploy with
`~/.claude/scripts/phone_deploy.sh ~/diet-guard/app --release`. Never uninstall
or `pm clear`.

**The phone is the user's daily driver — do not leave the app mid-flow, and do
not grab focus on their desktop.**

Verifying bug 1 needs an actual log: prefill a delivered dish, log it, and read
the entry back out of `food_log.json` after a sync. The kcal must match the
dish's own value, not a multiple of it. A green widget test is what let this
ship in the first place.

### Done

- A dish prefilled from the delivery logs its own macros exactly, with a stale
  `perGrams` present, proven by reading the written entry back.
- The corrupted 2026-08-23 owsianka entry reads 472 kcal.
- One tap on the log screen loads the delivery and walks it dish by dish, with
  the remaining count visible — observed on the phone.
