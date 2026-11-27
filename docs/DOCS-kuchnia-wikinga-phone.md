# Kuchnia Wikinga on the phone

The Dart half of the catering import. Read
[kuchnia-wikinga.md](kuchnia-wikinga.md) first — the API map, the traps and the
delivered-is-not-eaten rule all live there and are not repeated here.

`app/` carries a Dart mirror of the whole walk, so the feature works with the
PC switched off. The files map one-to-one:

| Python | Dart |
|---|---|
| `_kuchnia_client.py` | `services/kuchnia_client.dart` |
| `_kuchnia_orders.py` | `services/kuchnia_orders.dart` |
| `_kuchnia_parse.py` | `services/kuchnia_parse.dart` |
| `_kuchnia_spread.py` | `services/kuchnia_spread.dart` |
| `_kuchnia_import.py` | `services/kuchnia_import.dart` |
| `_gatelock_kuchnia.py` | `services/kuchnia_queue.dart` (fetched-today marker; the form prefill is gone) |
| `_kuchnia_log.py` (`fill_plan`, `log_dishes`) | `services/kuchnia_fill.dart` |
| `_gatelock_fillall.py` | `services/kuchnia_fill_flow.dart` (plan, no UI) + `services/kuchnia_autolog.dart` |

### Auto-log (replaces "Fill all" on the phone)

kuhy overrode "delivered is not eaten" on 2026-11-17 ("LOG EVEN WITHOUT TAP").
When the log screen opens or resumes with a slot due, `KuchniaAutoLog.logDue`
fetches today's delivery and logs the dishes assigned to the **due** slots, no
tap. The Fill all button, its confirm tap and the delivery prefill are gone
from the phone; `FillAllFlow` stays as the tested plan logic.

- **Plan = Fill all's plan minus the tap:** `assignSlots` by the caterer's
  `mealPriority` against the user's schedule, `fillPlan` over occupied slots,
  then only the due slots. Written by `logDishes`, source `kuchnia wikinga`.
- **Deterministic ids.** UUID v5, namespace `6ba7b811-9dad-11d1-80b4-00c04fd430c8`
  (RFC URL), over `kuchnia:<delivery date YYYY-MM-DD>:<dishKey>`; `dishKey` is
  the panel's `deliveryMealId` as a string, else the dish's bank key. A repeat
  open and every other device derive the same id, so the merge keeps one entry.
  `tests/fixtures/kuchnia_autolog_ids.json` (made by Python's `uuid.uuid5`,
  `scripts/build_kuchnia_autolog_fixture.py`) pins it for both languages.
- **Undo is a tombstone and it sticks.** `logMeal(id:)` and `logDishes(idFor:)`
  skip an id that exists in the full log, deleted entries included; otherwise
  undo plus the next resume would log the dish again.
- **The fetch is cached.** `KuchniaQueueService.refreshOnce` returns nothing
  after the day's first clean fetch, so a slot falling due at 12:00 would never
  see its dish. `KuchniaAutoLog` keeps the day's dishes in memory and in
  `kuchnia_delivery.json` (offline first: a restart or a panel outage still has
  them), and retries a failed or empty fetch at most every 10 minutes (a login
  per try). The PC keeps the same file (`_kuchnia_delivery_cache.py`).
- Each logged dish shows as a row: restaurant glyph, name, kcal and macro
  dots, a 48 dp undo. One publish per batch (`publishAfterLog`).
- Unverified: whether `deliveryMealId` is stable across fetches on the live
  panel (the fixtures carry scrubbed synthetic ids).

**Android only.** The panel sends no CORS headers, so a browser cannot call it;
`refreshDelivery` checks `kIsWeb` first and returns a reason. The settings
*fields* still show on web — the desktop app is where a password is most likely
to be typed, and the credential syncs from there to the phone.

`package:http` has no cookie jar, so the `SESSION` cookie is read off the login
response and replayed by hand. `Response.headers` folds duplicate `set-cookie`
values into one comma-joined string, so the parser splits on both `,` and `;`.

### What the parity gate covers, and what it does not

`tests/fixtures/kuchnia_day.json` is one payload with one expected result, read
by **both** `diet_guard/tests/test_kuchnia_parity.py` and
`app/test/kuchnia_parity_test.dart`. It pins the dish list, the dropped dishes,
the slot assignment, the bank keys and the encoded records. A second fixture,
`kuchnia_credential.json`, does the same for the credential adapter.

Three traps it exists for, each of which passed review once:

- **`_ENERGY_TOLERANCE` is 0.35**, not the "~1%" quoted above for the captured
  day. Porting 0.01 would drop dishes the PC keeps, and then each device
  re-adds what the other dropped.
- **`jsonEncode(435)` emits `435` where Python emits `435.0`.** Every Dart
  macro is declared `double`, and the fixture compares canonicalised encodings,
  not just values — `435 == 435.0` is true, so a value-only test misses this.
- **Dart's `List.sort` is unstable; Python's `sorted` is stable.** The Dart
  comparator carries the payload index as a final tiebreak, and the fixture
  contains two dishes sharing both a priority and a name.

The gate proves the two implementations agree **on a fixed payload**. It does
not prove they agree against the live panel on a given day; that is a separate,
on-device observation.
