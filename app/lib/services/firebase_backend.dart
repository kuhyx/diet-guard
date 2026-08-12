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
import 'package:diet_guard_app/services/google_sign_in_backend.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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

/// Returns a signed-in Firebase client, or null when not configured.
///
/// Signs in with the stored password only when there is no cached refresh
/// token, so the usual path costs no authentication round trip.
Future<FirebaseRestClient?> openFirebase() async {
  final account = await loadAccount();
  if (account == null) {
    // A stored refresh token is a signed-in device, even with no account
    // marker beside it. Treating the marker as the source of truth is what
    // turned one missing write into "syncs over GitHub and 401s forever":
    // the credential that actually authenticates was sitting in the keystore
    // the whole time, unused. Ask the store directly before giving up.
    return _clientFromStoredSession();
  }
  try {
    return await firebaseClientFor(
      config: kProject.configFor(account.email),
      store: credentialStore(),
      // A Google-provisioned account stores an empty password.
      // Passing '' would make firebaseClientFor treat it as a usable
      // credential and sign in with it, which fails; null correctly
      // means "no password on this device".
      password: account.password.isEmpty ? null : account.password,
      // Deliberately NOT offering Google here. This path runs from background
      // timers and, in some apps, before runApp -- offering it would let a
      // non-interactive tick raise the OS account picker with no user action
      // behind it. Interactive sign-in uses openFirebaseWithGoogle instead.
      expectedUid: kSyncUid,
    );
  } on Object catch (error, stackTrace) {
    // Unreachable keystore or a rejected sign-in must not fail the tick: the
    // app keeps syncing over GitHub, exactly as before the cutover.
    // Broader than Exception because an uninitialised platform binding
    // raises a FlutterError, which is an Error.
    //
    // Never silent, for the same reason loadAccount() above says why: a
    // signed-in-but-failing device looked exactly like an unconfigured one,
    // which is how the phone went days without publishing a single meal.
    log(
      'openFirebase failed; falling back to the GitHub mirror',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Whether this device can actually authenticate against Firebase.
///
/// True when either half of the state is present: the account marker
/// [loadAccount] reads, or a stored refresh token. The token is the half that
/// matters -- it is what signs requests -- so a settings screen that reports
/// the marker alone calls a working device "Not connected", which is how a
/// phone that was in fact syncing looked broken for a whole session.
Future<bool> isFirebaseConfigured() async {
  try {
    final auth = FirebaseTokenProvider(
      apiKey: kProject.apiKey,
      store: credentialStore(),
    );
    if (await auth.hasSession()) return true;
    // storedAccount, not loadAccount: on Android the latter falls back to the
    // desktop wrapper's /sync-account route, which resolves to file:/// and
    // throws "No host specified in URI" -- observed on the phone, where it
    // turned a successful sign-in into "Google sign-in failed".
    if (await storedAccount() == null) return false;
    // A marker with no session behind it cannot sign a single request. Drop
    // just the marker so the settings screen offers a sign-in instead of a
    // dead banner -- not clearAccount(), which also sets the opt-out flag and
    // would stop the desktop wrapper re-provisioning after the next sign-in.
    await _secure.delete(key: kFirebaseAccountKey);
    return false;
  } on Object catch (error, stackTrace) {
    log(
      'session probe failed; reporting this device as not configured',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  }
}

/// Returns a client built from the keystore's refresh token alone, or null.
///
/// The recovery path for a device that has a live session but no account
/// marker -- the state a Google sign-in used to leave behind. Costs one
/// keystore read and no network round trip when there is no session, so it is
/// safe on the background-tick path that [openFirebase] also serves.
///
/// Does not re-save the account: a device that reaches this is already signed
/// in, and writing a marker from a read path would hide the condition rather
/// than repair it. [openFirebaseWithGoogle] is what writes the marker.
Future<FirebaseRestClient?> _clientFromStoredSession() async {
  try {
    final auth = FirebaseTokenProvider(
      apiKey: kProject.apiKey,
      store: credentialStore(),
    );
    if (!await auth.hasSession()) return null;
    return FirebaseRestClient(databaseUrl: kProject.databaseUrl, auth: auth);
  } on Object catch (error, stackTrace) {
    // Same contract as openFirebase's own catch: an unreachable keystore
    // degrades to the GitHub mirror instead of failing the tick, but says so.
    log(
      'stored-session recovery failed; falling back to the GitHub mirror',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Signs in with Google alone, for a device that has no account stored yet.
///
/// This is the one-tap path: [openFirebase] needs an account in the keystore
/// to know which email to use, but a fresh install has none. The Google token
/// carries the identity, so nothing needs to be typed.
///
/// The account is stored under the email **Firebase reports**, never one read
/// from the UI: a fresh install has no email anywhere on the device, so taking
/// it from a text field would persist an empty account and send the next
/// launch down the password path with ''.
///
/// Returns null when the user dismisses the picker; throws [FirebaseAuthError]
/// when Google succeeds but resolves to a uid the security rules do not pin,
/// which would otherwise authenticate fine and then be denied every read and
/// write with no other symptom.
Future<FirebaseRestClient?> openFirebaseWithGoogle({
  Future<String?> Function()? tokenFetcher,
  Future<void> Function(FirebaseAccount)? accountSaver,
  http.Client? httpClient,
}) async {
  final token = await (tokenFetcher ?? googleIdToken)();
  if (token == null) return null;
  final auth = FirebaseTokenProvider(
    apiKey: kProject.apiKey,
    store: credentialStore(),
    httpClient: httpClient,
  );
  final email = await auth.signInWithGoogle(
    idToken: token,
    expectedUid: kSyncUid,
  );
  // The account must be saved unconditionally, and the signed-in email is not
  // reliable enough to gate it on. `signInWithIdp` omits `email` whenever the
  // Google account hides it, so gating the save on a non-null email produced
  // the worst possible outcome: this call returned a perfectly working client
  // -- "Connected to Firebase" -- while the device stayed unconfigured, so the
  // next launch found no account, `openFirebase()` returned null, and
  // `syncBackend()` silently dropped to GitHub-only and 401'd. The session is
  // already durable at this point (`signInWithGoogle` stores the refresh token
  // via `_adopt`); only this marker was missing, which is exactly why the
  // failure survived a restart and looked like a sign-in that never happened.
  //
  // The email is a display convenience, not the credential -- the refresh
  // token in the keystore is. An empty string is the honest value when Google
  // withholds it, and `openFirebase()` already treats an empty password as
  // "no password on this device" and authenticates from the stored token.
  await (accountSaver ?? saveAccount)(
    FirebaseAccount(email: email ?? '', password: ''),
  );
  return FirebaseRestClient(databaseUrl: kProject.databaseUrl, auth: auth);
}

// coverage:ignore-end

/// Wraps [github] so Firebase is primary and GitHub is kept as a mirror.
///
/// Returns [github] unchanged when this device has not been set up for
/// Firebase — a normal state during the cutover, not an error, and also the
/// rollback. Reads union both, so a device that has not moved yet still
/// converges.
Future<RemoteStore> syncBackend(RemoteStore github) async {
  final firebase = await openFirebase();
  return firebase == null
      ? github
      : MirrorStore(primary: firebase, mirror: github);
}
