/// HTTP access to the Kuchnia Wikinga panel, from the phone.
///
/// The Dart mirror of `diet_guard/_kuchnia_client.py`. Auth is a cookie
/// session, not a bearer token: `POST auth/login` with a **form-urlencoded**
/// body sets a `SESSION` cookie that every later call carries.
///
/// `package:http` has no cookie jar, so the `set-cookie` header is read and
/// replayed by hand. `Response.headers` folds duplicate `set-cookie` values
/// into one comma-joined string, which is why the parser below splits and
/// looks for the named cookie rather than assuming the header holds only it.
///
/// **Android only.** The panel sends no CORS headers, so a browser cannot call
/// it at all; on web every entry point returns an unsupported reason rather
/// than throwing. The `kIsWeb` check comes first, before anything
/// platform-shaped, and this file imports no `dart:io` -- `package:http`
/// compiles for web, it is the *panel* that refuses, not the toolchain.
library;

import 'dart:convert';

import 'package:diet_guard_app/services/kuchnia_errors.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Base URL of the panel's undocumented API.
const kuchniaApiBase = 'https://panel.kuchniavikinga.pl/api';

/// Sent as the `company-id` header. The panel wants the company *name*, not a
/// numeric id.
const kuchniaCompany = 'kuchniavikinga';

/// The panel's own launcher tag for a browser panel session.
const kuchniaLauncherType = 'BROWSER_PANEL';

/// The only cookie the panel issues on login.
///
/// It sets no `XSRF-TOKEN`, so the CSRF echo its own JavaScript performs is a
/// no-op for this account -- the session cookie alone authenticates.
const kuchniaSessionCookie = 'SESSION';

/// Per-request timeout.
const kuchniaTimeout = Duration(seconds: 8);

/// Whole-walk ceiling.
///
/// The import is three or four sequential requests, so a per-request timeout
/// alone would permit ~32s against a slow provider -- and this runs on a path
/// the user is waiting on.
const kuchniaTotalDeadline = Duration(seconds: 12);

/// Why the catering panel cannot be reached from a browser.
const kuchniaWebUnsupportedReason =
    'Android only — the catering panel blocks browser requests';

/// Extracts [name]'s value from a (possibly comma-joined) `set-cookie` header.
///
/// `http`'s `Response.headers` collapses repeated headers into one string, so
/// a panel that sets more than one cookie hands over
/// `SESSION=abc; Path=/, OTHER=def; Path=/`. Returns null when the cookie is
/// absent, which the caller treats as a failed login rather than guessing.
String? sessionCookieFrom(String? setCookieHeader) {
  if (setCookieHeader == null || setCookieHeader.isEmpty) return null;
  // Split on both separators: ',' joins whole cookies, ';' separates a
  // cookie's attributes from its value.
  for (final part in setCookieHeader.split(RegExp('[,;]'))) {
    final trimmed = part.trim();
    if (trimmed.startsWith('$kuchniaSessionCookie=')) {
      final value = trimmed.substring(kuchniaSessionCookie.length + 1);
      if (value.isNotEmpty) return value;
    }
  }
  return null;
}

/// A logged-in panel session with a whole-walk deadline.
class KuchniaSession {
  /// Creates a session over [client], authenticating lazily.
  KuchniaSession({
    required this.username,
    required this.password,
    http.Client? client,
    DateTime? startedAt,
  }) : _client = client ?? http.Client(),
       _deadline =
           (startedAt ?? DateTime.now()).add(kuchniaTotalDeadline);

  /// The panel e-mail.
  final String username;

  /// The panel password.
  final String password;

  final http.Client _client;
  final DateTime _deadline;

  /// The session cookie: seeded from a cache to skip the login, and read back
  /// afterwards so the caller can persist a freshly minted one.
  ///
  /// Device-local by design -- it is regenerable from the password, so syncing
  /// it would widen exposure and buy nothing.
  String? sessionCookie;

  Map<String, String> get _headers => {
    'company-id': kuchniaCompany,
    'X-Launcher-Type': kuchniaLauncherType,
    'User-Agent': 'diet_guard/1.0 (personal diet tracker)',
    'Accept': 'application/json',
    if (sessionCookie != null) 'Cookie': '$kuchniaSessionCookie=$sessionCookie',
  };

  void _checkDeadline() {
    if (!DateTime.now().isBefore(_deadline)) {
      throw const KuchniaError('catering panel too slow (deadline exceeded)');
    }
  }

  /// Authenticates and caches the session cookie.
  ///
  /// No client-wide `Content-Type`: the login body is form-urlencoded and a
  /// sticky JSON default would mislabel it. Passing a `Map` to `http.post`
  /// sets the right one automatically.
  Future<void> login() async {
    _checkDeadline();
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$kuchniaApiBase/auth/login'),
            headers: _headers,
            body: {'username': username, 'password': password},
          )
          .timeout(kuchniaTimeout);
    } on Exception catch (error) {
      throw KuchniaError('catering panel unreachable: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KuchniaError(
        'catering login rejected (HTTP ${response.statusCode})',
      );
    }
    final cookie = sessionCookieFrom(response.headers['set-cookie']);
    if (cookie == null) {
      throw const KuchniaError('catering login returned no session cookie');
    }
    sessionCookie = cookie;
  }

  /// GETs [path] and decodes it, re-logging in once if the cookie expired.
  ///
  /// A cached cookie that has expired is indistinguishable from a good one
  /// until it is used, so an auth failure is retried exactly once with fresh
  /// credentials. A second failure is real.
  Future<Object?> getJson(String path) async {
    if (sessionCookie == null) await login();
    var response = await _get(path);
    if (response.statusCode == 401 || response.statusCode == 403) {
      sessionCookie = null;
      await login();
      response = await _get(path);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw KuchniaError(
        'catering panel returned HTTP ${response.statusCode} for $path',
      );
    }
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw KuchniaError('catering panel returned a non-JSON body for $path');
    }
  }

  Future<http.Response> _get(String path) async {
    _checkDeadline();
    try {
      return await _client
          .get(Uri.parse('$kuchniaApiBase/$path'), headers: _headers)
          .timeout(kuchniaTimeout);
    } on Exception catch (error) {
      throw KuchniaError('catering panel unreachable: $error');
    }
  }

  /// Releases the underlying HTTP client.
  void close() => _client.close();
}

/// True when this platform can reach the catering panel at all.
///
/// False on web: the panel sends no CORS headers, so the browser refuses the
/// request before it leaves. Checked before anything platform-shaped runs.
bool get kuchniaFetchSupported => !kIsWeb;
