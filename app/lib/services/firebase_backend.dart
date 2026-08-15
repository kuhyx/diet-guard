/// Wiring for the Firebase backend, during and after the GitHub cutover.
///
/// Split by what is safe to publish, because this repo is public:
///
/// * [kProject] holds the Web API key and database URL. Both are public
///   identifiers that already ship inside the APK; the security rules, not
///   their secrecy, are what protect the data.
/// * The account email and password are entered once per device and kept in
///   the OS keystore, next to the GitHub token this app already stores there.
///
/// Nothing here reads `~/.config/crdt-sync/` — that is the desktop/Python
/// half. On Android there is no such file.
library;

import 'dart:developer';
import 'package:crdt_sync/crdt_sync.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The shared `kuhy-syncs` project.
///
/// `databaseUrl` is the **regional** host. The plain `*.firebaseio.com` form
/// answers 404 with a `correctUrl` body rather than an obvious error, which
/// reads like an auth failure and wastes a debugging session.
const kProject = FirebaseProject(
  apiKey: 'AIzaSyCF_sA3xCMehAYXK8eND-rAygb9NXXW_8E',
  databaseUrl:
      'https://kuhy-syncs-default-rtdb.europe-west1.firebasedatabase.app',
);

/// Same options the GitHub token uses: off Android's deprecated
/// `encryptedSharedPreferences` path, and libsecret on Linux.
const _secure = FlutterSecureStorage();

// Everything below reaches the OS keystore through a platform channel, which
// `flutter test` has no binding for -- the same reason `main.dart` and
// `openRepository()` are excluded. The logic these wrap (parsing, the
// public/private split, sign-in) lives in `crdt_sync` and is covered there at
// 100%; what is left here is the two-line adapter.
// coverage:ignore-start

/// The keystore-backed home for the Firebase refresh token.
SecureCredentialStore credentialStore() => SecureCredentialStore(
  read: (key) => _secure.read(key: key),
  write: (key, value) => _secure.write(key: key, value: value),
  delete: (key) => _secure.delete(key: key),
);

/// Reads the per-device account, or null when sync has not been set up.
Future<FirebaseAccount?> loadAccount() async {
  try {
    final stored = FirebaseAccount.tryParse(
      await _secure.read(key: kFirebaseAccountKey),
    );
    if (stored != null) return stored;
    // Disconnect must stick: without this the next launch would silently
    // re-adopt the account and the button would look broken.
    if (await _secure.read(key: kSyncAccountOptOutKey) != null) return null;
    // Desktop only in practice: on Android the wrapper does not exist, the
    // request fails, and this returns null exactly as before.
    final provisioned = await accountFromWrapper(Uri.base);
    if (provisioned != null) await saveAccount(provisioned);
    return provisioned;
  } on Object catch (error, stackTrace) {
    // Still "not configured" rather than crashing the settings screen -- but
    // never silent: this hid *why* provisioning failed, which is
    // indistinguishable from "no account set" until you say so.
    log(
      'loadAccount failed; treating this device as not configured',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Reads the account from the keystore only, with no wrapper fallback.
///
/// [loadAccount] falls back to the desktop wrapper's `/sync-account` route
/// when the keystore is empty, which on Android resolves to `file:///` and
/// throws `No host specified in URI`. Callers reading back an account they
/// just wrote -- where a fallback would be wrong anyway -- use this instead.
/// Verified on the phone: without it, sign-in succeeded and then the settings
/// screen hung on "Signing in..." forever.
Future<FirebaseAccount?> storedAccount() async =>
    FirebaseAccount.tryParse(await _secure.read(key: kFirebaseAccountKey));

/// Stores the per-device account. Keystore only — never prefs, never source.
Future<void> saveAccount(FirebaseAccount account) =>
    _secure.write(key: kFirebaseAccountKey, value: account.toJsonString());

/// Forgets the account and any cached session.
Future<void> clearAccount() async {
  await _secure.delete(key: kFirebaseAccountKey);
  // Suppress wrapper re-provisioning; see loadAccount().
  await _secure.write(key: kSyncAccountOptOutKey, value: 'true');
  await credentialStore().clear();
}

/// Drops just the stored account marker, leaving the opt-out flag alone.
///
/// Deliberately narrower than [clearAccount]: a marker with no session behind
/// it cannot sign a request, but setting the opt-out flag as well would stop
/// the desktop wrapper re-provisioning after the next sign-in.
Future<void> forgetAccountMarker() =>
    _secure.delete(key: kFirebaseAccountKey);
