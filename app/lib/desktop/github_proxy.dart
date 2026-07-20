/// The desktop wrapper's GitHub half: token storage, device flow, API proxy.
///
/// The desktop app runs in a browser, and a browser cannot do either half of
/// GitHub sync safely on its own:
///
/// * GitHub's **device-flow** endpoints (`github.com/login/device/code` and
///   the token poll) send no CORS headers, so a page cannot call them at all.
/// * A token held by the page would live in `localStorage` inside the Chrome
///   profile -- `flutter_secure_storage` on web is WebCrypto-wrapped
///   `localStorage` with the wrap key sitting beside the ciphertext, which is
///   obfuscation rather than encryption at rest.
///
/// This wrapper is a local process with neither limitation, so it owns the
/// token file and performs every authenticated call itself. The page never
/// sees the token: it asks for *status*, and its API requests are proxied
/// with the `Authorization` header attached here.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// GitHub's REST API base, which [GitHubProxy] fronts.
const githubApiBase = 'https://api.github.com';

/// GitHub's device-flow base (a different host, and CORS-less on purpose).
const githubDeviceBase = 'https://github.com';

/// Serves `/github/*` for the wrapper.
class GitHubProxy {
  /// Creates a proxy storing its token at [tokenPath], optionally seeding
  /// from [fallbackTokenPath] (the PC's own `diet_guard` sync token) when it
  /// has none of its own.
  GitHubProxy({
    required this.tokenPath,
    this.fallbackTokenPath,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  /// File this wrapper writes tokens to (mode 600).
  final String tokenPath;

  /// Optional pre-existing token to fall back to, so a PC that already
  /// configured `python -m diet_guard sync` needs no second setup.
  final String? fallbackTokenPath;

  final http.Client _http;

  /// Reads the stored token, or the empty string when there is none.
  Future<String> readToken() async {
    for (final path in [tokenPath, ?fallbackTokenPath]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      try {
        final token = (await file.readAsString()).trim();
        if (token.isNotEmpty) return token;
      } on FileSystemException {
        continue;
      }
    }
    return '';
  }

  /// Writes [token] (mode 600), or deletes the file when it is empty.
  Future<void> writeToken(String token) async {
    final file = File(tokenPath);
    if (token.isEmpty) {
      if (file.existsSync()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(token);
    // The token is a repo-scoped credential; keep it off other users' eyes
    // the same way the Python side's sync_token is stored.
    await Process.run('chmod', ['600', tokenPath]);
  }

  /// Handles a `/github/...` [request], with [rest] the path after `/github/`.
  ///
  /// Returns false when [rest] matches nothing, so the caller can 404.
  Future<bool> handle(HttpRequest request, String rest) async {
    switch (rest) {
      case 'auth/status':
        final token = await readToken();
        _json(request, {'configured': token.isNotEmpty});
        return true;
      case 'auth/token':
        await writeToken((await utf8.decoder.bind(request).join()).trim());
        request.response.statusCode = HttpStatus.noContent;
        return true;
      case 'auth/device/start':
        await _deviceStart(request);
        return true;
      case 'auth/device/poll':
        await _devicePoll(request);
        return true;
    }
    if (rest.startsWith('api/')) {
      await _proxyApi(request, rest.substring('api/'.length));
      return true;
    }
    return false;
  }

  Future<void> _deviceStart(HttpRequest request) async {
    final body = await _jsonBody(request);
    final response = await _http.post(
      Uri.parse('$githubDeviceBase/login/device/code'),
      headers: const {'Accept': 'application/json'},
      body: {'client_id': '${body['client_id']}', 'scope': 'repo'},
    );
    _passThrough(request, response);
  }

  Future<void> _devicePoll(HttpRequest request) async {
    final body = await _jsonBody(request);
    final response = await _http.post(
      Uri.parse('$githubDeviceBase/login/oauth/access_token'),
      headers: const {'Accept': 'application/json'},
      body: {
        'client_id': '${body['client_id']}',
        'device_code': '${body['device_code']}',
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      },
    );
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      _passThrough(request, response);
      return;
    }
    final token = decoded['access_token'];
    if (token is String && token.isNotEmpty) {
      await writeToken(token);
      // Deliberately does not echo the token back: the whole point of the
      // proxy is that the browser never holds it.
      _json(request, {'status': 'ok'});
      return;
    }
    // Still pending / denied / expired: the page drives the poll loop, so it
    // needs GitHub's own `error` value verbatim.
    _json(request, decoded..remove('access_token'));
  }

  Future<void> _proxyApi(HttpRequest request, String path) async {
    final token = await readToken();
    final uri = Uri.parse(
      '$githubApiBase/$path',
    ).replace(query: request.uri.query.isEmpty ? null : request.uri.query);
    final proxied = http.Request(request.method, uri)
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json',
      })
      ..bodyBytes = await _bodyBytes(request);
    final response = await http.Response.fromStream(await _http.send(proxied));
    _passThrough(request, response);
  }

  Future<Map<String, dynamic>> _jsonBody(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    }
  }

  Future<List<int>> _bodyBytes(HttpRequest request) async {
    final chunks = await request.toList();
    return [for (final chunk in chunks) ...chunk];
  }

  void _passThrough(HttpRequest request, http.Response response) {
    request.response
      ..statusCode = response.statusCode
      ..headers.contentType = ContentType.json
      ..add(response.bodyBytes);
  }

  void _json(HttpRequest request, Map<String, dynamic> body) {
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }

  /// Releases the outbound HTTP client.
  void close() => _http.close();
}
