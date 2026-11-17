/// Raw Realtime Database nodes for the relay, over REST.
///
/// The sync client (`FirebaseRestClient`) stores text blobs as string leaves;
/// the relay's units are JSON objects with a server-time sibling, so it needs
/// the node itself. Plain HTTPS like the sync client, so it works on Android
/// and in the browser-hosted desktop app alike.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// A relay call failed on the network or was refused. The message never holds
/// a URL: its query carries the ID token.
class RelayTransportError implements Exception {
  /// Creates the error.
  const RelayTransportError(this.message);

  /// What went wrong, safe to log.
  final String message;

  @override
  String toString() => 'RelayTransportError: $message';
}

/// The four node operations the relay needs.
abstract interface class RelayNodes {
  /// The JSON value at [path], or null when absent.
  Future<Object?> get(String path);

  /// The child keys of [path] (no values), empty when absent.
  Future<Set<String>> keys(String path);

  /// Replaces the node at [path] with [value].
  Future<void> put(String path, Object value);

  /// Deletes the node at [path].
  Future<void> delete(String path);

  /// Deletes [path] only while it holds neither a `claim` nor a `result`,
  /// atomically: the delete carries the node's ETag, so a worker claiming it
  /// in between turns the delete into a refusal. True when it is gone.
  Future<bool> deleteUnclaimed(String path);
}

/// [RelayNodes] over the Realtime Database REST API.
class RtdbNodes implements RelayNodes {
  /// Creates the client; [idToken] mints the token each request carries.
  RtdbNodes({
    required String databaseUrl,
    required this.idToken,
    http.Client? client,
    String namespace = '',
  }) : _base = databaseUrl.endsWith('/')
           ? databaseUrl.substring(0, databaseUrl.length - 1)
           : databaseUrl,
       _prefix = namespace.isEmpty ? '' : '$namespace/',
       _http = client ?? http.Client();

  /// Supplies a fresh Firebase ID token.
  final Future<String> Function() idToken;

  final String _base;
  final String _prefix;
  final http.Client _http;

  Future<Uri> _uri(String path, [Map<String, String> query = const {}]) async =>
      Uri.parse(
        '$_base/$_prefix$path.json',
      ).replace(queryParameters: {'auth': await idToken(), ...query});

  Future<http.Response> _send(
    String what,
    Future<http.Response> Function(Uri uri) call,
    String path, [
    Map<String, String> query = const {},
  ]) async {
    try {
      return await call(await _uri(path, query));
    } on http.ClientException catch (error) {
      throw RelayTransportError('network error $what: ${error.message}');
    }
  }

  Never _refuse(String what, http.Response res) =>
      throw RelayTransportError('$what refused: HTTP ${res.statusCode}');

  bool _ok(http.Response res) => res.statusCode >= 200 && res.statusCode < 300;

  @override
  Future<Object?> get(String path) async {
    final res = await _send('reading', _http.get, path);
    if (!_ok(res)) _refuse('reading', res);
    return jsonDecode(res.body);
  }

  @override
  Future<Set<String>> keys(String path) async {
    final res = await _send('listing', _http.get, path, {'shallow': 'true'});
    if (!_ok(res)) _refuse('listing', res);
    final decoded = jsonDecode(res.body);
    return decoded is Map ? decoded.keys.cast<String>().toSet() : {};
  }

  @override
  Future<void> put(String path, Object value) async {
    final res = await _send(
      'writing',
      (uri) => _http.put(uri, body: jsonEncode(value)),
      path,
    );
    if (!_ok(res)) _refuse('writing', res);
  }

  @override
  Future<void> delete(String path) async {
    final res = await _send('deleting', _http.delete, path);
    if (!_ok(res)) _refuse('deleting', res);
  }

  @override
  Future<bool> deleteUnclaimed(String path) async {
    // `X-Firebase-ETag` makes the read return the node's ETag; a claim or a
    // result written afterwards changes it, and `if-match` then answers 412.
    // A full read, not a shallow one: the ETag of a shallow answer is not
    // guaranteed to cover the children, and this path is rare.
    final read = await _send(
      'reading',
      (uri) => _http.get(uri, headers: {'X-Firebase-ETag': 'true'}),
      path,
    );
    if (!_ok(read)) _refuse('reading', read);
    final node = jsonDecode(read.body);
    if (node == null) return true;
    if (node is Map &&
        (node.containsKey('claim') || node.containsKey('result'))) {
      return false;
    }
    final etag = read.headers['etag'];
    if (etag == null) return false;
    final res = await _send(
      'deleting',
      (uri) => _http.delete(uri, headers: {'if-match': etag}),
      path,
    );
    if (res.statusCode == 412) return false;
    if (!_ok(res)) _refuse('deleting', res);
    return true;
  }
}
