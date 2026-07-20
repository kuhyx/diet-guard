// coverage:ignore-file
// Entry point for the desktop wrapper: resolves real paths, starts the
// server, and launches the browser. The serving logic it delegates to is
// covered by test/desktop/wrapper_server_test.dart.
import 'dart:io';

import 'package:diet_guard_app/desktop/github_proxy.dart';
import 'package:diet_guard_app/desktop/wrapper_server.dart';
import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'];
  if (home == null) {
    stderr.writeln('HOME is not set; cannot resolve the data directory.');
    exit(1);
  }

  // `dart build cli` emits bundle/bin/<exe> alongside bundle/lib/, so the
  // installed layout is /opt/diet-guard/bin/diet_guard_desktop with the web
  // assets one level up at /opt/diet-guard/web. --web-root overrides for
  // development runs straight out of the repo.
  final webRoot =
      _argValue(args, '--web-root') ??
      p.normalize(p.join(p.dirname(Platform.resolvedExecutable), '..', 'web'));
  if (!Directory(webRoot).existsSync()) {
    stderr.writeln('web assets not found at $webRoot');
    exit(1);
  }

  // Overridable so a verification run cannot touch the real data or the real
  // sync token.
  final dataDir =
      _argValue(args, '--data-dir') ??
      p.join(home, '.local', 'share', 'diet-guard-desktop');
  final proxy = GitHubProxy(
    tokenPath:
        _argValue(args, '--token-path') ??
        p.join(home, '.config', 'diet_guard_app', 'sync_token'),
    // The PC's Python gate already keeps a token for `diet-guard-sync.timer`;
    // reusing it means the desktop app needs no second setup on this machine.
    // Read-only: a token obtained here is written to our own path.
    fallbackTokenPath:
        _argValue(args, '--fallback-token-path') ??
        p.join(home, '.config', 'diet_guard', 'sync_token'),
  );

  final server = WrapperServer(
    webRoot: webRoot,
    dataDir: dataDir,
    gitHubProxy: proxy,
  );
  final port =
      int.tryParse(_argValue(args, '--port') ?? '') ?? desktopWrapperPort;
  await server.start(port);
  stdout.writeln('diet_guard desktop serving on http://localhost:$port');

  // A bare flag, not a valued option: requiring a dummy value meant passing a
  // stray positional, which the AOT runtime tries to interpret as a snapshot.
  if (!args.contains('--no-browser')) {
    final ranLongEnough = await _launchBrowser(home, port);
    if (!ranLongEnough) {
      // Chrome exits immediately when it hands the URL to an instance that
      // already owns the profile directory (or when a stale SingletonLock is
      // left behind). Shutting down here would pull the server out from under
      // a window that is still open, so keep serving instead.
      stdout.writeln(
        'Browser returned immediately (handed off to an existing window). '
        'Still serving on http://localhost:$port -- Ctrl-C to stop.',
      );
      return;
    }
    // Otherwise the browser owned the session: its window closed, so we exit.
    await server.stop();
  }
}

/// Launches the app in a Chrome-family browser with a **stable** profile
/// directory, since the food log, photos and settings live in that profile.
/// Returns true when the browser ran long enough to have owned the session.
Future<bool> _launchBrowser(String home, int port) async {
  // Ordered by preference, and deliberately broad: this machine runs Thorium
  // behind /opt/google/chrome, and has a policy that uninstalls the `chromium`
  // package, so assuming any single browser is wrong. DIET_GUARD_BROWSER
  // overrides.
  final candidates = [
    Platform.environment['DIET_GUARD_BROWSER'] ?? '',
    '/opt/google/chrome/chrome',
    '/opt/thorium-browser/thorium-browser',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/brave',
  ];
  final browser = candidates.firstWhere(
    (path) => path.isNotEmpty && File(path).existsSync(),
    orElse: () => '',
  );
  if (browser.isEmpty) {
    stderr.writeln(
      'No Chrome-family browser found; open http://localhost:$port manually.',
    );
    return false;
  }
  // The profile directory must stay as stable as the port: IndexedDB is keyed
  // by origin and lives inside this profile, so a changing path silently
  // hides the entire food log.
  final profile = p.join(
    home,
    '.local',
    'share',
    'diet-guard-desktop',
    'profile',
  );
  final process = await Process.start(browser, [
    '--app=http://localhost:$port',
    '--user-data-dir=$profile',
    // Sets WM_CLASS, which the .desktop entry matches on via StartupWMClass.
    // Without it the window inherits the browser's class and the taskbar shows
    // a browser icon instead of diet_guard's.
    '--class=diet_guard_app',
    '--no-first-run',
  ]);

  final started = DateTime.now();
  await process.exitCode;
  return DateTime.now().difference(started) > const Duration(seconds: 5);
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
