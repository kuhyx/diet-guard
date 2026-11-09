# Text kept on purpose (textgate keep list)

kuhy's rule: nothing he sees carries text unless he asked. `textgate scan`
still lists the rows below; each is documented here, and
`diet_guard/tests/test_textgate_scan_clean.py` fails on any hit this file
does not name by path. The per-surface guards are `test_gate_no_words.py`
and `test_gate_no_words_static.py` (Tk gate), `app/test/no_words_*_test.dart`
(phone and web screens) and `app/test/desktop/desktop_wrapper_no_text_test.dart`
(pages served into the Chrome window).

## Exempt

- `docs/explanations/*.html`: documentation pages, read in a browser on
  purpose. Not app UI. The scan lists them; the guard ignores that prefix.

## Proper nouns (OS-level app name)

| Where | Text | Why |
|---|---|---|
| `app/lib/main.dart` | `Diet Guard` | `MaterialApp.title`: task switcher and tab name |
| `diet_guard/_gatelock.py` | `Diet Gate` | window title, an identifier under override-redirect |

The launcher label and notification channel (`DietGuard`) live in
`AndroidManifest.xml` and `notification_backend_io.dart`; a due-slot
notification shows only the slot clock time and has no body.

## Spoken only (never painted)

| Where | Text | Evidence |
|---|---|---|
| `app/lib/screens/log_meal_fill_mixin.dart` | fill failed / cancelled sentences | handed to `StatusCue` as the semantic label; the cue paints a glyph and a count |
| `app/lib/services/kuchnia_fill_flow.dart` | delivery and logged sentences | `FillOutcome.message`, same route; `no_words_kuchnia_test.dart` proves the snackbar paints a glyph and a number |

## Read by Claude, not by kuhy

MCP tool titles in `diet_guard/_mcp.py` and `diet_guard/_mcp_read.py`, and the
commit text in `diet_guard/_prune_peers.py`: tool metadata and a CLI commit
message.

## Terminal output (settled: keeps its text)

All `print`/stdout/stderr and `--help` of the Python CLI, `app/bin/` and the
stderr lines of `app/lib/desktop/wrapper_server.dart`. Pages served into the
Chrome window answer errors with a status code and an empty body.

## DOUBT rows (kuhy to confirm or file a task)

- `MET` next to kcal figures (activity rows), and unit symbols `kcal kg lb st cm km min`: bare identifiers beside a number.
- Formula proper names painted outside the activity sheet: `app/lib/widgets/body/body_stats_cards.dart`, `goal_card.dart` (BMI Prime, Trefethen, ideal-weight and resting-burn formula names). The Tk gate dropped them.
- Workout names (`session.label`, `session.kind`) are PC-published content.

## Framework pickers (not reworked; follow-up task filed)

`showDatePicker`, `showDateRangePicker`, `showTimePicker` paint Select date,
Cancel, OK, Save: `log_meal_future_mixin.dart`, `history_filter_sheet.dart`,
`dated_value_card.dart`, `meal_time_dropdown.dart`, `profile_card.dart`.
