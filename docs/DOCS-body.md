# Body: profile, weight log, BMI, ideal weight, calorie targets, week plan

The **Body** tab (PC gate, `_gatelock_body*.py`) and the **Body** screen
(phone, `app/lib/screens/body_screen.dart`) show the same numbers from the
same synced data. Everything here is **informational**: nothing on either
surface writes the daily budget. The budget stays the number the user edits
by hand.

## What is stored, and where

One local document per device, `~/.local/share/diet_guard/body.json`
(phone: document `body` in the app's `DocumentStore`):

```json
{"v": 1,
 "profile": {"birth":     {"v": "1995-03-01", "t": "<iso edit time>"},
             "height_cm": {"v": 180.0,        "t": "..."},
             "sex":       {"v": "m",          "t": "..."}},
 "weights":  {"2026-09-27": {"kg": 81.2, "src": "phone", "t": "..."}},
 "bodyfat":  {"2026-09-27": {"pct": 16.8, "t": "..."}},
 "steps":    {"2026-09-27": {"n": 8421, "t": "..."}},
 "activity": {"sessions": [<session>, ...], "t": "..."}}
```

- **Profile** fields are independent: each has its own edit time and merges
  last-writer-wins on its own, so editing height on the phone cannot revert a
  birth date edited on the PC. `sex` is `"m"` or `"f"` (the Mifflin constant).
  This **reverses** the old "biometrics are used once and discarded" rule --
  the user asked for BMI and ideal weight, which need them permanently.
- **Weights**: one entry per local date. `kg: null` is a tombstone (a deleted
  day). `src` is `phone` (wake-alarm weigh-in), `manual` (typed on either
  device) or `init`.
- **Profile** also carries `goal` (the remembered calorie goal, below).
- **Body fat**: a dated log like weights (`pct: null` deletes a day). The
  newest reading switches the goal's BMR to Katch-McArdle.
- **Activity** is written **only by the PC** (the workout sources live
  there); the phone relays and displays it.
- **Steps** are written **only by the phone** (Health Connect, foreground
  only): per day, the steps whose intervals do not overlap any published
  session's `start..end`, so a recorded walk is not also counted as steps.

## Wire format

Pushed as `diet-guard-sync/devices/<device-id>/body.json`, a `crdt_sync` Log:

| record id        | field      | value                                   |
|------------------|------------|-----------------------------------------|
| `profile`        | `birth`    | `"YYYY-MM-DD"`                          |
| `profile`        | `height_cm`| number                                  |
| `profile`        | `sex`      | `"m"` / `"f"`                           |
| `profile`        | `goal`     | `{"dir","amt","wu","tu","act"}`         |
| `w:<YYYY-MM-DD>` | `kg`       | `{"kg": number or null, "src": string}` |
| `bf:<YYYY-MM-DD>`| `pct`      | `{"pct": number or null}`               |
| `st:<YYYY-MM-DD>`| `n`        | `{"n": integer}`                        |
| `activity`       | `sessions` | list of session objects (below)         |

Every field's Hlc is `wall_time_ms` = its `t`, node = this device's sync id
(same determinism trick as `sync_merge/_budget.py`: an unchanged entry
re-derives the same clock, so re-syncing is a no-op). Unparsable `t` → epoch.
Malformed values are skipped on read, never raised.

Session object: `{"day": "YYYY-MM-DD", "kind": "strength|run|walk|cycle|other",
"min": 60.5, "km": 5.61 or null, "label": "...", "src": "runnerup|screen-locker",
"start": ISO or absent, "end": ISO or absent}`. Windows come from the TCX start
+ duration, a manual workout's `start_time`/`end_time`, or a verified
workout's log stamp (its end) minus its minutes.

## Phone weigh-ins (wake-alarm) → weights log

Both devices ingest on every sync tick, straight from Firebase:
`wake-alarm-sync/devices/*/alarm.json`, record `alarm`, fields
`[value, hlc]`:

- `latest_weight_kg` = `{"date", "kg"}` → entry `{kg, src: "phone"}` stamped
  with **that field's Hlc wall time** (a re-typed weigh-in is newer and wins).
- `morning_sessions` = list of sessions with `date` and `weight_kg` → entries
  stamped `<date>T00:00:00+00:00`: they only fill gaps. The list is
  republished every morning with a new Hlc, so using that Hlc would overwrite
  every manual correction daily.

A candidate replaces the local entry for its date only if the local entry is
missing or has an **older** `t`. Any manual edit is stamped "now", so it
outranks an ingested weigh-in of the same day. kg outside 20..400 is ignored.
`morning_sessions` keeps only the newest few mornings, so the backfill is
shallow -- history accumulates from here on.

The newest non-deleted weight also refreshes the budget record's `w` (the
protein target) on the PC, under the same rule `_phone_weight` always used:
only when its date is later than the budget's last edit day.

## Workouts → exercise kcal (PC, `_activity_sources.py`)

Sources, last 28 days, deduplicated so one workout counts once:

- **RunnerUp TCX** in `~/data/cloud/RunnerUp/` and `processed/`: sport,
  total seconds, distance. The files carry `<Calories>0</Calories>` and no
  heart rate, so energy must be estimated.
- **screen-locker** `log.json` via lazy `import screen_locker` (never raises;
  missing package → no strength sessions):
  `pc_workout_verified` (StrongLifts, `duration_minutes`) → strength;
  `phone_verified` only on a day with no `pc_workout_verified` (it is the same
  session reported from the phone; minutes parsed from `(86 min`);
  `manual_workout` → kind from `activity_type`/`sport`, else from the words
  walk/run/jog/hike in any text field, with a distance ("5 km", "3500 m")
  read from that text (`_manual_workout_parse.py`);
  `runnerup_verified` only on a day with no TCX (same run, TCX is richer);
  `relaxed_day_skip` → nothing.

Formulas (`_activity_kcal.py`), all **net** of resting burn: MET (Compendium
2011, speed-interpolated for runs/walks; lifting 5.0), ACSM run/walk
equations from speed, and Per-km (0.9 / 0.5 kcal/kg/km). Steps above 4000/day
(`_body_steps.py`: stride = height × 0.415 m, 0.5 kcal/kg/km) are added to
every formula's daily total. Heart-rate input was dropped at the user's call.

## Calculations (`_body_calc.py`, `_body_energy.py`, `_week_plan.py`)

- **BMI** kg/m², BMI Prime, Trefethen; WHO bands, not applied under 20.
- **Ideal weight**: Devine, Robinson, Miller, Hamwi (undefined < 152.4 cm),
  Broca, modified Broca, Lorentz, Creff (the one that uses age), Peterson;
  then their average and min-max "ideal range". The BMI 18.5-24.9 healthy
  range sits with BMI.
- **BMR**: Mifflin-St Jeor, Harris-Benedict (1984), and with a body fat
  Katch-McArdle and Cunningham (lean mass). The goal uses Katch-McArdle when
  body fat exists, else Mifflin.
- **Goal** (`_body_energy.py`, the top line): "To lose 0.5 kg / week on
  Moderate eat N kcal". Direction lose/maintain/gain; any amount; weight unit
  kg/lb/g/st; time unit day/week/month (30.436875 d)/year (365.2425 d);
  activity = one of 5 factors (1.2 / 1.375 / 1.55 / 1.725 / 1.9) or Measured
  (MET/ACSM/Per-km) = BMR × 1.2 + mean daily net exercise over the 14 full
  days before today. Target = TDEE − kg/day × 7700. Under 1200 is flagged,
  never clamped. Saved (synced) on every change.
- **Week plan**: Monday-Sunday; typed days and logged past days are known,
  the rest share `(target×7 − known) / remaining`. A past day with no log is
  `unlogged` and planned like a remaining day.

Rounding is `half_up` on both sides, never `round`.

## Parity

`tests/fixtures/body_calc.json` (from `scripts/build_body_fixture.py`) is
asserted by `diet_guard/tests/test_body_parity.py` and
`app/test/services/body_parity_test.dart`. Change a formula → regenerate →
read the diff → both suites must pass.
