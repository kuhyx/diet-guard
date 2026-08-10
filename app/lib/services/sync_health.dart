/// Whether this device is actually publishing, and when it last managed to.
///
/// Exists because the failure it reports was invisible for days: the phone
/// held meals nobody else could see, the PC's gate kept locking for slots that
/// *were* logged, and every screen looked completely normal. A sync that
/// silently stops must not be indistinguishable from a sync with nothing to
/// say, so the outcome of every tick is recorded here and surfaced by
/// [SyncHealthBanner] on the log screen.
///
/// This is the *only* signal that reaches the user on a release build. The
/// `log()` calls at each failure site go to `dart:developer`, which surfaces
/// through the VM service and **not** logcat on a release APK -- verified on
/// device: zero Dart-side lines appear under `adb logcat` even from paths that
/// definitely ran. So the logging is for a debug session; the banner is what
/// makes a stalled sync noticeable in real use. Do not "simplify" this away in
/// favour of logging alone.
///
/// Backed by SharedPreferences rather than a [DocumentStore] because a
/// WorkManager background isolate writes it too: prefs need no per-isolate
/// init, and a lost health stamp is cosmetic, never user data.
library;

import 'package:shared_preferences/shared_preferences.dart';

/// How stale the last success may get before the banner appears.
///
/// Comfortably longer than the ~15 min periodic tick, so one missed or
/// battery-deferred tick stays quiet and only a real stall shows up.
const Duration kSyncStaleAfter = Duration(hours: 6);

/// Why the last tick did not publish, or null when it did.
enum SyncFailureKind {
  /// No backend at all: neither a Firebase account nor a GitHub token.
  unconfigured,

  /// A backend is configured but the attempt threw (offline, auth, remote).
  failed,
}

/// Records and reports the outcome of sync attempts.
abstract final class SyncHealth {
  static const _kLastSuccess = 'sync.health.lastSuccessMs';
  static const _kFailureKind = 'sync.health.failureKind';

  /// Marks a tick that actually reached the remote.
  static Future<void> recordSuccess() => _withPrefs((prefs) async {
    await prefs.setInt(_kLastSuccess, DateTime.now().millisecondsSinceEpoch);
    await prefs.remove(_kFailureKind);
  });

  /// Marks a tick that could not publish because nothing is set up.
  static Future<void> recordUnconfigured() =>
      _recordFailure(SyncFailureKind.unconfigured);

  /// Marks a tick that had a backend but failed to publish.
  static Future<void> recordFailure() =>
      _recordFailure(SyncFailureKind.failed);

  static Future<void> _recordFailure(SyncFailureKind kind) =>
      _withPrefs((prefs) => prefs.setString(_kFailureKind, kind.name));

  /// The current health, for the banner.
  ///
  /// Reports "healthy" when prefs are unreachable: a banner that cannot read
  /// its own state must not accuse a working device of being stalled.
  static Future<SyncHealthStatus> read({DateTime? now}) async {
    final at = now ?? DateTime.now();
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } on Object {
      return SyncHealthStatus(lastSuccess: null, failureKind: null, now: at);
    }
    final millis = prefs.getInt(_kLastSuccess);
    final stored = prefs.getString(_kFailureKind);
    return SyncHealthStatus(
      lastSuccess: millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis),
      failureKind: SyncFailureKind.values
          .where((value) => value.name == stored)
          .firstOrNull,
      now: at,
    );
  }

  /// Forgets all recorded health. Test-only.
  static Future<void> resetForTest() => _withPrefs((prefs) async {
    await prefs.remove(_kLastSuccess);
    await prefs.remove(_kFailureKind);
  });

  /// Runs [action] against prefs, ignoring an unreachable platform channel.
  ///
  /// Health is diagnostics about syncing, never user data, so it must never
  /// take down the caller. Under `flutter test` the shared_preferences channel
  /// is unmocked by default and throws [MissingPluginException] -- the same
  /// reason [runSync]'s callers treat that as equivalent to being offline.
  static Future<void> _withPrefs(
    Future<void> Function(SharedPreferences prefs) action,
  ) async {
    try {
      await action(await SharedPreferences.getInstance());
    } on Object {
      // Losing a health stamp costs a banner, never a meal.
    }
  }
}

/// A snapshot of whether this device is publishing.
class SyncHealthStatus {
  /// Creates a snapshot evaluated as of [now].
  const SyncHealthStatus({
    required this.lastSuccess,
    required this.failureKind,
    required this.now,
  });

  /// When this device last published successfully, or null if it never has.
  final DateTime? lastSuccess;

  /// Why the most recent attempt did not publish, or null when it did.
  final SyncFailureKind? failureKind;

  /// The moment this snapshot was evaluated against.
  final DateTime now;

  /// True when the user should be told that syncing has stopped.
  ///
  /// A device that has never synced is *not* flagged: a fresh install with no
  /// account yet is a normal state, and nagging there would train the banner
  /// to be ignored. Only a device that used to work, or one that explicitly
  /// failed, is worth interrupting for.
  bool get isStalled {
    if (failureKind == SyncFailureKind.failed) return true;
    final last = lastSuccess;
    if (last == null) return false;
    return now.difference(last) > kSyncStaleAfter;
  }

  /// One line explaining the state, or null when there is nothing to say.
  String? get message {
    if (!isStalled) return null;
    if (failureKind == SyncFailureKind.unconfigured) {
      return 'Not syncing: no account connected. Meals stay on this device.';
    }
    final since = lastSuccess == null ? null : now.difference(lastSuccess!);
    // An elapsed time is only worth showing once it has actually elapsed.
    // A sync that failed moments after a success rendered "Not syncing since
    // 0h ago", which reads like a bug in the banner rather than a report
    // about the sync.
    if (since == null || since < const Duration(hours: 1)) {
      return 'Not syncing. Meals stay on this device.';
    }
    return 'Not syncing since ${_ago(since)}. Meals stay on this device.';
  }

  static String _ago(Duration since) {
    if (since.inDays >= 1) {
      return '${since.inDays}d ago';
    }
    return '${since.inHours}h ago';
  }
}
