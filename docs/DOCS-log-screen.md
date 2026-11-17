# The phone's log screen

`app/lib/screens/log_meal_screen.dart` and its mixins. Approved design: kuhy,
2026-11-17, mockup variant 1A. **No painted words**: every control is an icon.

## Two modes

- **Due mode** (`missingSlots` is non-empty): no app bar, sync banner, date row,
  slot chips or Fill all; the Android status bar is hidden (immersive) and put
  back on exit and on `dispose`. `main.dart` sets no system-UI mode, so "back"
  means both bars visible. Only the food field, a fixed-height suggestion block,
  the macro fields (2 rows of 3) and the action row remain.
- **Normal mode** (nothing due): the old screen minus the slot chips and Fill
  all, plus the same action row. Notifications are unchanged.

Until the first read of today's log the screen draws neither (no app-bar flash).
`logMealClock` (`log_meal_due_mixin.dart`) is the clock; the suite pins it to
07:00 in `flutter_test_config.dart`, and a test needing due mode calls
`pinLogMealClock`.

## Slot targeting

No slot picker. Due mode: both the check and the sparkle target the **oldest
due slot** (`dueSlots.first`). Normal mode: `slotForLog` (nearest). The integer
slot maths in `models/slot.dart` is untouched. A *future* date (the date row,
normal mode only) keeps its own slot row, because it has no due slots to derive
from.

## The action row (1A)

Photo (blue; tap = camera, long press = gallery; attached = tinted with a check
badge and a remove badge, **never a thumbnail**), Claude (gold sparkle), log
(green check). Sparkle and check are greyed until there is text (or, for the
sparkle, a photo). The sparkle shows a spinner while sending, an hourglass when
queued (PC offline), a lock when sync is locked, an error glyph on failure
(a tap retries).

**The food field never moves.** Spinners, logged rows and cues go *below* the
action row. `log_meal_geometry_test.dart` asserts, on 1080x2400 at 2.625 with
the Pixel insets and a 320 dp keyboard, that the field's top is identical in
every state and `maxScrollExtent == 0`. Macro values of four digits must paint
whole at 16 sp or more (`macro_input_row_test.dart` measures the digits; a
`Row` of `Expanded` fields clips them without any exception).

## Logged rows and undo

After a Claude, check or catering log, a row (origin glyph, name, kcal and macro
dots, a 48 dp round undo, no countdown) shows under the action row until the
next meal is logged. Undo is `deleteEntry(id)` plus `publishAfterLog`, a
tombstone by id (several rows can be on screen, so not `undoLastToday`).

## Claude and photos

The sparkle talks to `ClaudeRelayClient` (`services/claude_relay_client.dart`),
injectable; `FakeClaudeRelayClient` drives the tests. The request id becomes the
logged entry's id. A photo is **transient input**: `image_picker` scales it to
1024 px JPEG, the bytes are read into memory and the plugin's cache file is
deleted at once (`meal_photo_cleanup_io.dart`). It is never stored, put on a
`FoodEntry`, or synced; `repo_invariants_test.dart` asserts it structurally. The
camera runtime permission is requested before the camera opens.

Catering auto-log: [DOCS-kuchnia-wikinga-phone.md](DOCS-kuchnia-wikinga-phone.md).
