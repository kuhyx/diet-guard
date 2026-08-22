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

Two files under `~/.config/diet_guard/`, both mode 600, both **outside** the
synced tree — a password and a live session cookie must not travel to another
device.

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

Three, all event-driven. **No new systemd timer** — `diet-guard-sync.timer` was
deliberately deleted and `install.sh` actively uninstalls it.

| | Where | Guarded? |
|---|---|---|
| CLI | `diet-guard kuchnia` | no — an explicit ask always goes and looks |
| Gate | `MealGate.on_focus_ready` → `_autoload_delivery` | yes |
| After a meal | `_cli_log.cmd_ate`, on the existing background thread | yes |

The guarded pair go through `refresh_delivery_once`, which skips the walk when
today has already been fetched (`kuchnia_last_import`, one ISO date). Without
it the after-log hook would pay a login plus three requests after *every* meal.
Only a clean fetch records the date, so an outage is retried.

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
- **The phone needs no importer.** It receives the curated bank and the log
  through existing sync, and `FoodBankRecord.fromJson`/`toJson` enumerate a
  fixed key set — a provenance field written by the PC would be silently
  dropped on every round-trip, producing an endless re-add/re-strip ping-pong.

## Re-probing the API

`scripts/probe_kuchnia.py` (login, order walk) and
`scripts/probe_kuchnia_details.py` (which URL form serves a day's meals) dump
redacted JSON captures. Run the first, then the second. They prompt once and
cache the session, and credential/cookie *values* never reach the dump.
