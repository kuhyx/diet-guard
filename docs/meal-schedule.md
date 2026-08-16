# The meal schedule (`_meal_schedule.py` / `meal_schedule.dart`)

_Split out of `CLAUDE.md` to keep it under the repo's 250-line cap._

The user sets a first meal hour, a last meal hour, and how many meals fall
between them; the intermediate checkpoints are derived by even division.
`MealSchedule(8, 20, 5)` → `08:00, 11:00, 14:00, 17:00, 20:00`. The default
`MealSchedule(8, 20, 4)` reproduces the hours that used to be hardcoded, so an
existing install sees no change until it is edited.

Four rules, each load-bearing:

- **Integer arithmetic only** — see the `Do NOT` entry below. The shared
  test-vector table plus an identical 0..23 × 0..23 × 2..6 sweep in
  `test_meal_schedule.py` and `meal_schedule_test.dart` is what catches a
  cross-language divergence before it reaches a device.
- **Slots stay whole hours.** Changing that changes the on-disk log's `slot`
  tag and the sync wire format, on both devices.
- **Counts are clamped to the window width** (`last - first + 1`), because a
  narrow window would otherwise round two meals onto the same hour, and slot
  hours are set members, dict keys *and* notification ids — a duplicate
  silently drops a checkpoint. The two edit surfaces reject such input with a
  message; `normalized()` clamps it, which is the defence against a peer's
  corrupt sync data rather than the input contract.
- **The enforcement cutoff is `last + 2h`, clamped to midnight.** It is a
  grace period for a late dinner, deliberately independent of meal count.
  Unclamped, a 23:00 last meal gives 25 and `hour < cutoff` is vacuously
  true — the window never closes.

`_slots.py` / `slot.dart` take the schedule as a **required** argument. A
default there would let a call site missed in a refactor keep deriving the old
fixed hours on one device only, which is the split brain that can lock the
user out; making it required lets mypy and `flutter analyze` enumerate the
sites. Callers resolve it at the impure edge through
`_meal_schedule_store.current_schedule()` / `MealScheduleService.current`.

The history is forward-only (`_meal_schedule_store.py` /
`meal_schedule_history.dart`), so switching from four meals to five does not
retroactively mark past days as having missed a checkpoint. It seeds the
default at `1970-01-01` **before** recording today's value — same ordering
requirement as `_budget_history.py`. It syncs as `sched:<YYYY-MM-DD>` fields
on the existing `budget` CRDT record, so devices predating the feature relay
them untouched.

Editable on both surfaces: the app's Settings screen
(`settings_meal_schedule.dart`) and the gate's History tab
(`_gatelock_scheduleedit.py`).

**Notification ids are slot hours.** `syncToSlots` must sweep the whole 0..23
id space, not the current schedule's slots — otherwise a schedule change
orphans the ids it no longer contains and they nag forever.
