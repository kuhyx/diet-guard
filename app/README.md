# diet_guard_app

Companion app for `diet_guard`: log meals on the phone, and on the Linux
desktop, sharing one food log through GitHub-backed sync.

## Two targets, and only two

| Target | What it is |
|---|---|
| Android | a normal Flutter app (`flutter build apk`) |
| Linux desktop | the Flutter **web** build, served by a local wrapper and shown in a Chrome `--app` window |

There is no `linux/` directory. Flutter's GTK embedder manages ~20fps at
3840x2160 -- measured on a stock `flutter create` counter app, so it is the
toolkit rather than this code -- where the same Dart rendered by Chrome
sustains ~144fps (`~/todo/docs/desktop-performance-findings.md`). Running
`flutter create --platforms linux` here would silently restore the slow path.

## Commands

```bash
flutter test                     # the app's suite
flutter analyze
bash run.sh                      # build the web bundle and launch the desktop app
bash install_arch.sh             # build + install the pacman package and .desktop entry
flutter build apk --release      # the phone build
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Never `adb uninstall` or `pm clear` this package: both wipe the on-device log.

## The desktop wrapper

`bin/diet_guard_desktop.dart` is the other half of the desktop app, because a
browser cannot touch the filesystem. It:

- serves the built web assets from `build/web` (or `/opt/diet-guard-app/web`
  once packaged);
- keeps an on-disk copy of every document and photo under
  `~/.local/share/diet-guard-desktop/`, which is what makes a wiped Chrome
  profile recoverable -- for photos it is the *only* copy, since they never
  sync;
- holds the GitHub token (`~/.config/diet_guard_app/sync_token`, falling back
  to the PC gate's `~/.config/diet_guard/sync_token`) and proxies
  `api.github.com` plus the device flow, whose endpoints send no CORS headers
  and so cannot be called from a page at all.

**The port (8732) and the Chrome `--user-data-dir` must stay fixed.**
IndexedDB is keyed by origin and lives inside that profile, so changing either
looks to the app like a device with no history.

## Platform seams

`dart:io` does not fail a web *compile*; it becomes a stub that throws at
runtime, so the symptom of a missed seam is a blank white window rather than a
build error. Every platform edge is a conditional export -- `document_store*`,
`blob_store*`, `background_tasks*`, `notification_backend*`, `token_vault*`,
`github_client_factory*`, `attached_image*`. Branch on `kIsWeb` *before* any
`Platform.is…`, which itself throws on web.

What the desktop genuinely loses, by design rather than omission:

- **Background reminders.** A browser runs nothing once its window is closed,
  so the due-slot check runs in-page every 5 minutes while the window is open.
  On the PC the real backstop is `diet-guard-gate.timer`, which locks the
  screen.
- **Camera capture.** The browser picker is a file input.
- **Photo sharing between devices** -- unchanged: `imagePath` was always
  stripped before push.

## Sync identity

Three devices push under `diet-guard-sync/devices/`: `pc` (the Python gate),
`phone`, and `desktop`. Each must keep its own id -- two devices sharing one
would overwrite each other's pushed log on every tick.
