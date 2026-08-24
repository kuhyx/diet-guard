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
| `_gatelock_kuchnia.py` | `screens/log_meal_kuchnia_mixin.dart` + `services/kuchnia_queue.dart` |

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
