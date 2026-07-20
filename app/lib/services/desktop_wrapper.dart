/// Shared constants between the web app and the desktop wrapper that serves it.
library;

/// The fixed port the desktop wrapper serves on.
///
/// **Do not change this casually.** IndexedDB (the food log, the food bank,
/// the settings and the photo blobs) is keyed by origin, so a different port
/// looks like a different app with no history at all. The launcher, the
/// packaging and `bin/diet_guard_desktop.dart` must all use this value, and
/// the Chrome `--user-data-dir` must stay equally fixed for the same reason.
///
/// 8730 is `~/todo`'s wrapper and 8731 is `~/habit_stack`'s; this is the next
/// free one so all three can run at once.
const desktopWrapperPort = 8732;

/// Origin of the desktop wrapper, e.g. `http://localhost:8732`.
const desktopWrapperOrigin = 'http://localhost:$desktopWrapperPort';

/// URL paths the wrapper serves.
///
/// Kept beside the port so the client and the server cannot drift apart; the
/// server mirrors these constants rather than re-spelling the strings.
abstract final class WrapperPaths {
  /// Prefix for document reads/writes: `/documents/<name>`.
  static const documents = '/documents/';

  /// Prefix for photo-blob reads/writes: `/blobs/<key>`.
  static const blobs = '/blobs/';

  /// Prefix for the GitHub proxy (see `wrapper_server.dart`).
  static const github = '/github/';
}
