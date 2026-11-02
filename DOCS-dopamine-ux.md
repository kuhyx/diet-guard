# diet-guard dopamine-ux: context

## context you would otherwise rediscover

- This app has **no `design_system` dependency** — `app/lib/ui/theme.dart` is a
  hand-transcription of the shared tokens (values are byte-identical, names in
  comments). Motion tokens from prompt 01 must be **transcribed into that local
  theme file**, matching the existing convention. Do not add the dependency here;
  that is a separate, larger refactor.
- Capability baseline, verified 2026-08-16: **no audio package, no `assets:`
  block, no `vibration` package, no VIBRATE permission.** The only existing
  audio-adjacent thing is the `diet_guard_due_slot` notification channel
  (`app/lib/services/notification_backend_io.dart` ~:17-18, :52-55) at
  `Importance.high` with no explicit sound/vibration override — leave it alone.
- The app already computes both a **logging streak** and an **adherence streak**
  (`_daystatus.py:144`/`:153` on the Python side, mirrored in Dart). You are
  making existing true data feel like something, not inventing a new metric.
- diet-guard state lives under XDG (`~/.local/share/diet_guard`), unlike
  screen-locker's in-repo JSON. Tests isolate it via
  `~/src/diet-guard/diet_guard/tests/conftest.py:97` `_isolate_state`.
