# Kuchnia Wikinga catering import

Pulls the day's delivered dishes — with their real per-portion macros — out of
`panel.kuchniavikinga.pl` and into diet_guard, so a catering meal is one
keypress instead of five retyped numbers.

## What it does, and deliberately does not

**A delivered meal is not an eaten meal.** Dishes land in the *curated* food
bank; entries are only ever written after an explicit confirmation. If the
importer logged automatically, the gate would satisfy its own checkpoint from a
delivery note, and the log would record what the courier dropped off rather than
what was eaten — skipped, shared and binned meals included.

So:

- **`diet-guard kuchnia`** banks the day's dishes and prints them. Nothing is
  logged.
- **`diet-guard kuchnia --log`** asks first (`--yes` skips the prompt for
  scripting).
- **The lock screen's "🍱 Today's delivery"** button *prefills* the meal form,
  dish by dish, in the caterer's own meal order. The user still clicks
  "Log & Continue" for each.

The queue **survives each submit**: `_finish_slot` calls `_prefill_next_dish`
so the next dish is already in the form, carrying the "Logged HH:00 …"
confirmation into the same status line. One button click walks the whole
delivery. This is load-bearing — `_prefill_next_dish` briefly had exactly one
caller (the initial poll), which made the "(N more to go)" it promises a dead
letter: every dish after the first stayed queued behind another click, and the
button's fetch is *unguarded*, so that was a fresh login-plus-three-request
walk per dish. `test_kuchnia_queue.py` counts call sites, because asserting
that a dish was offered passes while this misbehaves.

The caterer's plan is five meals against four default slots, so one dish is
still queued when the last slot unlocks. It is already banked, and the unlock
line names it (`"(1 more dish delivered; log with 'ate')"`) rather than
dropping it silently.

## The API (undocumented, recovered by inspection)

The panel is a white-labelled **Dietly** React SPA. There is no published API;
the endpoint map was recovered from its Vite bundles and confirmed against live
responses on 2026-08-22. Re-check if the bundle hashes change.

| | |
|---|---|
| Base | `https://panel.kuchniavikinga.pl/api` |
| Login | `POST auth/login`, **form-urlencoded** `username=…&password=…` |
| Session | a `SESSION` cookie — **not** a bearer token |
| Headers | `company-id: kuchniavikinga` (the company *name*), `X-Launcher-Type: BROWSER_PANEL` |

The walk is three calls:

1. `company/customer/order/active-ids` → `[orderId]`
2. `company/customer/order/{orderId}` → the order, which **embeds every
   delivery** with its date. No enumeration call needed — but `deliveryMeals`
   carries ids only, no names and no macros.
3. `company/general/menus/delivery/{deliveryId}/new` → the actual menu.

Three traps worth knowing before touching `_kuchnia_orders.py`:

- **`.../deliveries/{id}/details` does not work.** It 404s (400 keyed by date),
  verified against three separate delivery days, despite being the obvious name
  and the one the bundles pass a `deliveryId` to. The menu endpoint above is
  the one that answers.
- **`deliveryId` is opaque, never a date.** The date form 400s.
- **No `XSRF-TOKEN` cookie is issued**, so the CSRF echo the panel's own
  JavaScript performs is a no-op here. The client skips it when absent rather
  than sending an empty header.

### Macros are per portion

`nutrition` = `{weight, calories, protein, carbohydrate, fat, dietaryFiber,
sugar, salt, saturatedFattyAcids}`. **`weight` is the portion in grams and the
macros are totals for that portion**, which maps straight onto diet_guard's
`grams`/`kcal`/`protein_g`/`carbs_g`/`fat_g`.

This was proven, not assumed: 4·protein + 4·carbs + 9·fat reproduces the stated
`calories` within ~1% on every meal of the captured day, and the day totals
2055 kcal against the plan's declared 2000.

`_kuchnia_parse._energy_is_consistent` re-runs that check on every dish and
**drops any that fails**. A per-100 g/per-portion mix-up is invisible in a
payload and would silently skew every logged meal by a factor of several, so
the parser refuses rather than importing a plausible-looking lie.

## Credentials

Three files under `~/.config/diet_guard/`, all mode 600. They are outside
`DATA_DIR` so they stay off the *food-log* sync path — but one of them, the
credential itself, **does travel between devices**.

**The password syncs, in plaintext.** The phone runs its own importer and
cannot fetch without it, and a phone that has been wiped needs it back without
the user digging out the original. It rides its own document
(`diet_guard/sync_merge/_kuchnia.py`, `devices/<id>/kuchnia.json`), not the
budget record — `budget.json` is written back at default permissions, so a
password inside it would be readable by anything that reads the budget. Nothing
encrypts it, and the rest of the synced state is not encrypted either, so do
not describe it as "encrypted like everything else". This is a deliberate
trade: the alternative was a phone that cannot fetch at all, and the blast
radius is a catering menu and a delivery address.

**The session cookie does not sync.** It is regenerable from the password, so
copying it around would widen exposure and buy nothing.

| file | written by | syncs? |
|---|---|---|
| `kuchnia_credentials` | the user, by hand | no — a local override, and the bootstrap for the first push |
| `kuchnia_synced_credential.json` | the sync layer | **yes**, as its own record |
| `kuchnia_session.json` | the client, on login | no |

`kuchnia_credentials` wins over the synced copy when present, so a machine-local
override always works. It is never *pushed*, though — only used to bootstrap
when no device has published a credential yet. Its mtime is the only edit time
it has, and `git checkout`, a backup restore or re-running the `install` line
below all bump it without the credential changing; letting that compete in the
merge let a merely-touched file overwrite a password just typed on the phone.

```bash
install -m 600 /dev/null ~/.config/diet_guard/kuchnia_credentials
printf '%s\n%s\n' 'you@example.com' 'your-password' \
  > ~/.config/diet_guard/kuchnia_credentials
```

`kuchnia_credentials` is **written by hand and never by the package**, the same
contract as `sync_token`. `kuchnia_session.json` caches the session cookie so a
refresh normally skips the login round trip; it is created `touch(mode=0o600)`
*before* it holds anything, then atomically replaced — writing and chmod'ing
afterwards would leave a live cookie world-readable for the duration.

Missing or unreadable credentials are not an error at the call site: the fetch
returns a reason string and the caller carries on.

## Triggers

All event-driven. **No new systemd timer** — `diet-guard-sync.timer` was
deliberately deleted and `install.sh` actively uninstalls it.

| | Where | Guarded? |
|---|---|---|
| CLI | `diet-guard kuchnia` | no — an explicit ask always goes and looks |
| Gate | `MealGate.on_focus_ready` → `_autoload_delivery` | yes |
| After a meal | `_cli_log.cmd_ate`, on the existing background thread | yes |
| Phone: log screen | `LogMealKuchniaMixin.loadTodaysDelivery` on `initState` | yes |
| Phone: settings | the "Fetch today's delivery" button | no — same rule as the CLI |

The guarded ones go through `refresh_delivery_once` (Python) or
`KuchniaQueueService.refreshOnce` (Dart), which skip the walk when today has
already been fetched. Without that the after-log hook would pay a login plus
three requests after *every* meal. Only a clean fetch records the date, so an
outage is retried.

The marker is **device-local on both sides** — `kuchnia_last_import` under
`~/.config` on the PC, `kuchnia_last_import.json` in the app's document store
on the phone. It is a rate limit, not shared state: syncing it would let one
device's fetch suppress the other's.

**Why the gate hook is in `on_focus_ready` and not `_cli_gate._should_lock`:**
`gate_is_due()` reads only the food log and the schedule, never the food bank,
so a catering refresh there could not change the lock decision — while adding a
third-party round trip to the ~105ms `gate --check` fast path, which opens no
window at all. Hooking it once the window is up puts the spinner *inside* the
lock instead of in front of it. An automatic fetch is also silent about bad
news: it must not talk over the prompt telling the user which slots to fill.

## Things that will bite

- **Re-banking unchanged dishes floods sync.** `add_manual_entry` restamps `t`
  unconditionally and the merge derives each record's clock from it, so a
  refresh that re-banks everything republishes the whole curated bank to every
  peer. `bank_dishes` compares the nutritional fields first. Tests assert on
  **call count** — "the entry exists" passes while this misbehaves.
- **Imports go to `food_bank_manual.json` only.** The derived bank is rewritten
  from the log on every meal, so anything written there vanishes.
- **Duplicate log suppression reads today's log, not a marker.** `log_meal`
  mints a fresh uuid per entry, so a re-import after a lost marker would merge
  as duplicates on every peer. Matching `desc`+`slot` against the synced log is
  robust to marker loss *and* correct across devices.
- **`requests` is lazy-imported.** The gate's not-due tick imports the CLI and
  must not pay ~78ms for an HTTP stack it never touches. Call sites reach
  through `sys.modules[__name__]` so `patch.object` still wins.
- **The phone has its own importer, and the two must agree exactly.** It no
  longer merely receives the curated bank: it fetches, parses and banks the
  day's dishes itself, so the feature works with the PC switched off. That
  makes three things load-bearing across two languages — which dishes are
  *dropped*, which *slot* each lands on, and the exact JSON a banked record
  encodes to. A disagreement on any of them means each device re-adds what the
  other dropped; `add_manual_entry` restamps `t` unconditionally, so the whole
  curated bank republishes to every peer on every refresh. A slot mismatch is
  worse: a checkpoint one device offers and the other does not can never be
  satisfied.

  Gated by **one shared fixture**, `tests/fixtures/kuchnia_day.json`, asserted
  by `diet_guard/tests/test_kuchnia_parity.py` *and*
  `app/test/kuchnia_parity_test.dart`. Two suites written independently from
  the same prose is not a gate; one input with one expected result is.
  Regenerate it with `scripts/build_kuchnia_fixture.py`, and re-read the diff
  before committing — the script blesses whatever Python currently does.

  Three traps the fixture pins, each of which passed review once:
  `_ENERGY_TOLERANCE` is **0.35**, not the ~1% the prose above quotes for the
  captured day; `jsonEncode(435)` emits `435` where Python emits `435.0`, so
  every Dart macro is forced to `double`; and Dart's `List.sort` is unstable
  where Python's `sorted` is stable, so the Dart comparator carries the payload
  index as a final tiebreak.

- **Bank records still round-trip losslessly through the Dart model.**
  `FoodBankRecord.fromJson`/`toJson` enumerate a fixed key set — a provenance
  field written by the PC would be silently dropped on every round-trip,
  producing an endless re-add/re-strip ping-pong.
  `app/test/kuchnia_bank_interop_test.dart` round-trips a verbatim capture of a
  real imported bank through the Dart model, diacritics and `t` stamp included.
- **The two devices normalize bank keys with different primitives** — Python
  `str.casefold()`, Dart `String.toLowerCase()`. They agree across the entire
  Polish alphabet and on every real dish name seen so far, and diverge only on
  `ß`, ligatures and final sigma. Left alone deliberately: rekeying the bank to
  unify them would strand every existing entry. The Dart test above pins the
  agreement, so a future non-Polish dish name cannot break it unnoticed.

## The phone runs the same import

`app/` carries a Dart mirror of the whole walk, so the feature works with the
PC switched off — including the cross-language parity gate that keeps the two
from drifting. See [kuchnia-wikinga-phone.md](kuchnia-wikinga-phone.md).

## Re-probing the API

`scripts/probe_kuchnia.py` (login, order walk) and
`scripts/probe_kuchnia_details.py` (which URL form serves a day's meals) dump
redacted JSON captures. Run the first, then the second. They prompt once and
cache the session, and credential/cookie *values* never reach the dump.
