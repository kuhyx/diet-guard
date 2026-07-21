# Design audit — diet-guard

Generated against safe-design-rules (anthonyhobday.com/sideprojects/saferules).
Report only — nothing in this repo was changed by the audit itself.

This repo has two UI surfaces, audited separately below.

---

## Flutter app (`app/`)

Theme entry point: `app/lib/main.dart:52` —
`ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true)`. This is the
**entire** theme definition: no `darkTheme`, no `textTheme` override, no
component themes (`elevatedButtonTheme`, `cardTheme`, etc.), no
`ThemeExtension`. Everything downstream of this one line either inherits
Material 3's generated defaults or bypasses the theme with raw `Colors.*`
literals in individual widgets — sampled across `screens/` and `widgets/`
(11 of 21 files).

### Violations

- **Rule 1 (near-black/near-white)** — `app/lib/widgets/day_status_calendar.dart:79` uses `Colors.black` for the "not logged" cell fill, and `:87`/`:121` use pure `Colors.white` for text — both bypass the muted near-black/near-white the seeded `ColorScheme` would otherwise supply.
- **Rule 2 (saturate neutrals)** — `app/lib/widgets/day_status_calendar.dart:78,104` (`Colors.grey.shade800`) and `app/lib/widgets/slot_selector_row.dart:49` (`Colors.grey`) use Material's generic, zero-chroma grey instead of a grey tinted toward the teal seed.
- **Rule 4 (everything deliberate)** — no centralized token beyond the one-line `ThemeData` call; `day_status_calendar.dart` (8 raw `Colors.*` refs), `slot_selector_row.dart` (4 raw refs, lines 46-49), and `settings_screen.dart:567` each invent status/error colors independently instead of reading `Theme.of(context).colorScheme`.
- **Rule 4 (inconsistency, concrete pair)** — the same semantic "error" state is styled two different ways in the same app: `history_screen.dart:603` uses `Theme.of(context).colorScheme.error`, but `settings_screen.dart:567` hardcodes `Colors.red` for the same purpose.
- **Rule 9 (distinct brightness values)** — `day_status_calendar.dart:80-82` mixes `Colors.red.shade400` (lighter) with `Colors.amber.shade700` / `Colors.green.shade700` (darker) for three parallel status swatches meant to read as one family — inconsistent shade selection, not a deliberate brightness ramp.
- **Rule 11 (mathematically related measurements)** — corner radii are inconsistent across near-identical use cases: `BorderRadius.circular(8)` in `day_status_calendar.dart:105` and `photo_attach_field.dart:95` vs `BorderRadius.circular(6)` in `history_screen.dart:638` for the same "thumbnail clip" purpose, with no shared base unit.
- **Rule 20 (body text ≥16px)** — `day_status_calendar.dart:123` (`fontSize: 14`), `:146` (`fontSize: 11`), `:181` (`fontSize: 12`) are all below the 16px minimum, with no larger default applied elsewhere to compensate for this widget.
- **Rule 28 (icon contrast lower than text)** — `slot_selector_row.dart:54` (`Icon(..., color: color)`) and `:57` (`labelStyle: TextStyle(color: color)`) give the check icon and its adjacent label text the *same* full-strength color — the icon should read lighter/lower-contrast than the text, not equal.

### Passes worth recording

- **Rule 3** — clear hierarchy exists elsewhere: `history_screen.dart:603` correctly pulls the delete/error action from `colorScheme.error`.
- **Rule 18 (container brightness limits)** — only one nested-container case was found (`day_status_calendar.dart`'s `grey.shade800` panel on the default light scaffold); no evidence of a violation.
- **Rule 23 (two typefaces max)** — no `fontFamily` or `google_fonts` import anywhere in `app/lib/` — the whole app uses exactly one (system default) typeface.
- **Rule 26 / 27 (shadows/depth)** — no `BoxShadow`, `elevation:`, or `Card(` usage found in the sampled files; zero depth technique used, so it's trivially consistent (though see Notes — this also means rule 15/16/17 have nothing to evaluate).
- **Rule 28 (partial pass)** — `day_status_calendar.dart:113,127` (`Colors.white70` chevron icons) sit next to `:121` (`Colors.white` full-opacity month label) — here the icon *is* correctly lower-contrast than the text.

### Not applicable

- Rule 5 (optical alignment) — no asymmetric icon/shape widgets found requiring hand-tuned centering.
- Rule 6 (letter-spacing/line-height by size) — no manual `letterSpacing`/`height` found anywhere in `screens/`/`widgets/`; the app relies entirely on Material 3's built-in type scale, which already encodes this rule.
- Rule 7 (container border contrast) — the one border found (`day_status_calendar.dart:172-174`, `Colors.white70` on `Colors.black`) has adequate contrast against both surfaces; no counter-evidence.
- Rule 8 (everything aligns) — default `MainAxisAlignment.spaceBetween`/`spaceAround` usage throughout; no counter-evidence gathered.
- Rule 10 (warm or cool, not both) — the app doesn't saturate its neutrals at all (see Rule 2 violation above), so warm/cool consistency has nothing to check.
- Rule 12 (order by visual weight) — no clear violation or pass identified from the sampled files; would need a full-screen layout review.
- Rule 13 (12-column grid) — mobile-first single-column screens; no grid system in use.
- Rule 14 (space between high-contrast points) — insufficient evidence gathered from the sample.
- Rule 15 (closer = lighter) — no elevation/z-stacking found to evaluate (see Rule 26/27 pass note).
- Rule 16 (shadow blur ≈ 2× distance) — no `BoxShadow` in the codebase.
- Rule 17 (simple on complex) — flat design throughout; no complex background/foreground pairing to break the rule.
- Rule 19 (outer padding ≥ inner padding) — holds everywhere checked, e.g. `day_status_calendar.dart:102` (`EdgeInsets.all(12)` outer) vs `:168` (`EdgeInsets.symmetric(vertical: 2)` cell margin).
- Rule 21 (line length ~70 chars) — no long-form body text in the sampled screens (mostly labels/numbers).
- Rule 22 (button padding h=2×v) — no explicit `ButtonStyle.padding` override found anywhere; buttons run on Material 3 defaults, which already approximate this ratio.
- Rule 24 (nest corners) — no nested corner-radius container pairs found to check a concentric relationship.
- Rule 25 (avoid adjacent hard divides) — insufficient evidence gathered from the sample.

### Notes

- The theme is effectively unstyled beyond a seed color. Every rule above that reads "no evidence"/"insufficient evidence" is really a symptom of the same root cause: there is no `theme.dart`, no `ThemeExtension` for semantic colors (success/warn/danger), and no component themes, so status colors (green/red/amber/grey) get re-invented per-widget instead of being defined once. Centralizing those into a `ThemeExtension` (e.g. `DietGuardStatusColors`) would fix the Rule 4/9/28 violations above in one pass and make Rule 15/16/17/18/26/27 actually checkable against a real design system instead of "nothing to evaluate."
- `day_status_calendar.dart`'s status colors (`red.shade400`/`amber.shade700`/`green.shade700`) do not literally match the Python gatelock's calendar palette (`#ff5555`/`#e0c33c`/`#33cc66` — see Python section below) even though the widget's own doc comment (`day_status_calendar.dart:9`) says it "mirrors" that view. Worth reconciling into one shared value if visual parity between the phone app and the PC lock screen actually matters.

---

## Python/Tkinter gatelock UI (`diet_guard/`, not `app/`)

Files audited: `_gatelock_ui.py` (474 lines), `_gatelock_mealflow.py` (349),
`_gatelock_calendar.py` (466), `_gatelock_core.py` (196),
`_gatelock_nutrition.py` (230), `_gatelock.py` (211), `_gatelock_support.py`
(82), `_calendar_view.py` (151).

**Correction to prior research going in:** there *is* a color-constants block
(`_gatelock_ui.py:27-32`: `BG`, `FG`, `_ACCENT`, `ERR`, `_FIELD_BG`,
`_MUTED`), so "no color/theme constants module" is not quite right — the
real problem is worse than absence: it's **triplication**. `_gatelock_ui.py`
is the closest thing to a canonical module, but `_gatelock_calendar.py:58-60`
and `_calendar_view.py:25-33` each **redefine their own copies** of the same
values instead of importing them (see Violations below). `_gatelock_calendar.py:55-57`
even has a comment justifying this: *"BG/FG/ERR come from `_gatelock_ui`'s
public exports; the rest are private to that module, so equivalents are
defined locally rather than reaching across the boundary."* That's a
structural decision (avoid touching another module's private names) that
produces exactly the drift risk a shared module is supposed to prevent.
Confirmed **no `ttk.Style()` call anywhere** in the 8 files (0 grep hits).
Hex-literal count is also off from the prior estimate: **25 occurrences of
12 distinct hex values** (not ~4) across the 3 files that define palette
constants. Inline `font=` literal count is confirmed accurate: **35
occurrences**.

### The shared `LockConfig.bg` token

`~/utils/gatelock/gatelock/_window.py:71` — `LockConfig.bg: str = "#1a1a1a"`
is the one real shared design token in this family (used by `screen-locker`,
`wake_alarm`, and `diet_guard` alike via `GateRoot`/`LockWindow`).

- `diet_guard/_gatelock_ui.py:27` — `BG = "#1a1a1a"` **re-hardcodes the same
  literal instead of importing `gatelock.LockConfig.bg`**. It happens to
  match today, but nothing keeps it in sync — if `LockConfig`'s default ever
  changes, this constant silently goes stale.
- `diet_guard/_gatelock.py:147` — `LockConfig(mode=..., bg=BG)` then passes
  that duplicated literal back into `LockConfig` explicitly. This call is
  redundant today (it matches `LockConfig`'s own default) and masks the
  duplication: it *looks* like `diet_guard` is deliberately overriding the
  background, when it's actually just echoing the default via a second,
  unlinked constant.
- Fix direction (report-only, not applied): `_gatelock_ui.py` should import
  `LockConfig.bg` (or a `LockConfig()` default instance's `.bg`) rather than
  defining its own `BG` literal, and `_gatelock.py:147` should drop the
  explicit `bg=BG` kwarg entirely once it's provably redundant.

### Violations

- **Rule 1 (near-black/near-white)** — `_calendar_view.py:25` `_NOT_LOGGED_FILL = "#000000"` is pure black; `_gatelock_ui.py:434` and `:459` (`fg="white"`) are pure white. This is inconsistent with the rest of the palette, which correctly uses `#1a1a1a`/`#e0e0e0` (near-black/near-white, not pure).
- **Rule 2 (saturate neutrals)** — every neutral in the shared palette is a zero-chroma grey (equal R/G/B hex pairs): `BG "#1a1a1a"`, `_FIELD_BG "#2a2a2a"`, `_MUTED "#9a9a9a"` (`_gatelock_ui.py:27,31,32`), plus the duplicate `LockConfig.bg = "#1a1a1a"` (`gatelock/_window.py:71`). None carry any tint — exactly the "generic gray" this rule warns against.
- **Rule 4 (everything deliberate / centralization)** — `_MUTED = "#9a9a9a"` is defined **three times** verbatim: `_gatelock_ui.py:32`, `_gatelock_calendar.py:58`, `_calendar_view.py:33`. `"#003322"` (status text color) is likewise defined 3×: `_gatelock_ui.py:191,421`, `_gatelock_calendar.py:154`, `_calendar_view.py:32`. `_FIELD_BG "#2a2a2a"` and `_ACCENT "#00ff88"`/`"#00cc66"` are each duplicated across `_gatelock_ui.py` and `_gatelock_calendar.py`. No `ttk.Style()` centralizes any of this.
- **Rule 11 (mathematically related measurements)** — font sizes in use: 10, 11, 12, 13, 14, 15, 16, 22, 30 (`_gatelock_ui.py` and `_gatelock_calendar.py`, e.g. `_gatelock_ui.py:130,145,161,285,371,378`) — no common ratio or base unit. Spacing is similarly mixed: `ipady=3` (`_gatelock_ui.py:147,216`) vs `ipady=2` (`:256,330`; `_gatelock_calendar.py:148`) used interchangeably for the same "entry field" role.
- **Rule 20 (body text ≥16px)** — the dominant font size is 12pt (9 occurrences in `_gatelock_ui.py` alone: lines 161,185,209,225,249,260,334,343,... ) with many labels at 11-13pt; only headline-style text (22, 30) clears a 16px-equivalent minimum.

### Passes worth recording

- **Rule 3 (high contrast for important elements)** — `_gatelock_ui.py:416-425` ("Log & Continue", the primary action) uses bright `_ACCENT #00ff88`; `:429-438` ("Fetch from sync", secondary) uses a muted `#334455`/`#445566` pair. Clear, deliberate hierarchy.
- **Rule 9 (distinct brightness values)** — `_calendar_view.py:28-30`: `GREEN #33cc66` / `YELLOW #e0c33c` / `RED #ff5555` are visually distinct hues at roughly matched brightness — better-executed than the Flutter app's equivalent (see Flutter Rule 9 violation above).
- **Rule 18 (container brightness limits)** — `BG "#1a1a1a"` (~10% luma) vs `_FIELD_BG "#2a2a2a"` (~16% luma), a ~6% delta — comfortably within the ~12% dark-interface guideline (`_gatelock_ui.py:27,31`).
- **Rule 19 (outer padding ≥ inner padding)** — outer frame padding (e.g. `padx=6` at `_gatelock_ui.py:144`) is consistently ≥ field-level `ipady=2-3`.
- **Rule 23 (two typefaces max)** — exactly two families used: "Arial" (34 occurrences) and "Courier" (1 occurrence, `_gatelock_ui.py:292`).
- **Rule 26 / 27 (no shadows / single depth technique)** — `relief=` (Tk's raised/sunken/groove bevel, its closest thing to a shadow) is never used in any of the 8 files (0 grep hits); zero depth technique applied, trivially consistent.

### Not applicable

- Rule 5 (optical alignment) — no asymmetric icon/shape widgets in this Tk UI.
- Rule 6 (letter-spacing/line-height by size) — Tk's `font=` tuples have no letter-spacing control and no independent line-height axis; not expressible in this toolkit.
- Rule 7 (container border contrast) — `highlightthickness` varies 0/1/2 (`_gatelock_ui.py:174,193,229`; `_gatelock_calendar.py:235`) but the one case with a matched-to-background `highlightbackground` (`_calendar_view.py:108-115`, future-day cells) is intentional per its own docstring (`day_status_calendar.dart:9`-equivalent design: blend future days into the background), not a rule violation.
- Rule 8 (everything aligns) — grid/pack-based layout; no counter-evidence gathered.
- Rule 10 (warm or cool, not both) — the neutrals aren't saturated at all (Rule 2 violation above), so there's no warm/cool choice to be consistent about.
- Rule 12 (order by visual weight) — not assessed from the sampled files.
- Rule 13 (12-column grid) — fixed-size fullscreen dialog, not a column-grid layout.
- Rule 14 (space between high-contrast points) — insufficient evidence gathered.
- Rule 15 (closer = lighter) — Tk has no z-stacking/elevation concept; nothing to evaluate.
- Rule 16 (shadow blur ≈ 2× distance) — Tk has no drop-shadow primitive; unused.
- Rule 17 (simple on complex) — flat single-color backgrounds throughout; no complex imagery to conflict with.
- Rule 21 (line length ~70 chars) — `wraplength=900` (pixels, e.g. `_gatelock_ui.py:410,446`) is a pixel wrap, not a character-count guarantee; can't verify without rendering.
- Rule 22 (button padding h=2×v) — no `tk.Button` in the sampled files sets explicit `ipadx`/`ipady`; only `Entry` widgets do (grep-confirmed). Buttons run on Tk's own default padding, unexamined by this rule.
- Rule 24 (nest corners) — Tk widgets here are flat-relief rectangles; no corner-radius concept applies.
- Rule 25 (avoid adjacent hard divides) — insufficient evidence gathered.
- Rule 28 (icon contrast lower than text) — this UI uses unicode glyphs embedded in button `text=` (e.g. `"⟳ Fetch from sync"` at `_gatelock_ui.py:431`, `"✕ Close Demo"` at `:456`) rather than a separately-styled icon widget; there's no independent icon-vs-text contrast axis to check.

### Notes

- The real fix for the Python surface's Rule 4 violations is structural: promote `_gatelock_ui.py`'s 6 constants (plus `_calendar_view.py`'s status-color dict) into one importable module that every gatelock file reads from, and have that module import `gatelock.LockConfig`'s `bg` default rather than re-literal-ing `"#1a1a1a"`. That single change collapses 3 duplicate `_MUTED`/`"#003322"` definitions and closes the `LockConfig.bg` drift risk in one pass.
- Because `LockConfig.bg = "#1a1a1a"` is shared by `screen-locker` and `wake_alarm` too, if those repos independently re-hardcode `"#1a1a1a"` the same way `diet_guard` does, this is a family-wide pattern, not a `diet_guard`-only one — worth a follow-up grep across those repos if/when this gets fixed.
