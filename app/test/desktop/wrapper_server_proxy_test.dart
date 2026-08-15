// The desktop wrapper is the other half of the web-build desktop app: it
// serves the assets, owns the on-disk mirror of the app's storage, and fronts
// GitHub. These tests drive it over a real loopback socket, since its
// contract is HTTP.
import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/desktop/github_proxy.dart';
import 'package:diet_guard_app/desktop/wrapper_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {


  late Directory tempDir;
  late String webRoot;
  late String dataDir;
  late WrapperServer server;
  late List<http.Request> outbound;
  late Map<String, http.Response> canned;

  Future<void> startServer({
    bool serveSyncAccount = false,
    String? syncConfigDir,
  }) async {
    outbound = [];
    canned = {};
    final proxy = GitHubProxy(
      tokenPath: p.join(tempDir.path, 'config', 'sync_token'),
      fallbackTokenPath: p.join(tempDir.path, 'config', 'fallback_token'),
      httpClient: MockClient((request) async {
        outbound.add(request);
        return canned[request.url.toString()] ??
            http.Response('{"ok":true}', 200);
      }),
    );
    server = WrapperServer(
      webRoot: webRoot,
      dataDir: dataDir,
      gitHubProxy: proxy,
      serveSyncAccount: serveSyncAccount,
      syncConfigDir: syncConfigDir,
    );
    await server.start(0);
  }

  Uri url(String path) => Uri.parse('http://localhost:${server.port}$path');

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_wrapper_');
    webRoot = p.join(tempDir.path, 'web');
    dataDir = p.join(tempDir.path, 'data');
    await Directory(webRoot).create(recursive: true);
    File(p.join(webRoot, 'index.html')).writeAsStringSync('<html>app</html>');
    File(p.join(webRoot, 'main.wasm')).writeAsBytesSync([0, 97, 115, 109]);
    await startServer();
  });

  tearDown(() async {
    await server.stop();
    await tempDir.delete(recursive: true);
  });

  group('github proxy', () {
    test('reports no token before one is stored', () async {
      final response = await http.get(url('/github/auth/status'));

      expect(jsonDecode(response.body), {'configured': false});
    });

    test('stores a pasted token and then reports configured', () async {
      await http.post(url('/github/auth/token'), body: 'ghp_pasted');

      final response = await http.get(url('/github/auth/status'));

      expect(jsonDecode(response.body), {'configured': true});
      expect(
        File(p.join(tempDir.path, 'config', 'sync_token')).readAsStringSync(),
        'ghp_pasted',
      );
    });

    test(
      'falls back to the PC gate token when it has none of its own',
      () async {
        // The Python side already keeps a token for diet-guard-sync.timer;
        // reusing it is what makes the desktop app need no second setup.
        final fallback = File(p.join(tempDir.path, 'config', 'fallback_token'))
          ..createSync(recursive: true)
          ..writeAsStringSync('ghp_from_gate\n');
        addTearDown(fallback.deleteSync);

        final response = await http.get(url('/github/auth/status'));

        expect(jsonDecode(response.body), {'configured': true});
      },
    );

    test('attaches the token to a proxied API call', () async {
      await http.post(url('/github/auth/token'), body: 'ghp_stored');
      canned['https://api.github.com/repos/kuhyx/syncs'] = http.Response(
        '{"name":"syncs"}',
        200,
      );

      final response = await http.get(url('/github/api/repos/kuhyx/syncs'));

      expect(response.body, '{"name":"syncs"}');
      expect(outbound.single.headers['Authorization'], 'Bearer ghp_stored');
    });

    test('keeps a device-flow token server-side', () async {
      canned['https://github.com/login/oauth/access_token'] = http.Response(
        '{"access_token":"ghp_device"}',
        200,
      );

      final response = await http.post(
        url('/github/auth/device/poll'),
        body: jsonEncode({'client_id': 'cid', 'device_code': 'dc'}),
      );

      // The point of the proxy: the browser is told "ok", never the token.
      expect(jsonDecode(response.body), {'status': 'ok'});
      expect(response.body, isNot(contains('ghp_device')));
      expect(
        File(p.join(tempDir.path, 'config', 'sync_token')).readAsStringSync(),
        'ghp_device',
      );
    });

    test('passes a still-pending device-flow poll straight back', () async {
      canned['https://github.com/login/oauth/access_token'] = http.Response(
        '{"error":"authorization_pending"}',
        200,
      );

      final response = await http.post(
        url('/github/auth/device/poll'),
        body: jsonEncode({'client_id': 'cid', 'device_code': 'dc'}),
      );

      expect(jsonDecode(response.body), {'error': 'authorization_pending'});
    });

    test('forwards the device-code request with the client id', () async {
      canned['https://github.com/login/device/code'] = http.Response(
        '{"device_code":"dc","user_code":"ABCD-1234"}',
        200,
      );

      final response = await http.post(
        url('/github/auth/device/start'),
        body: jsonEncode({'client_id': 'cid'}),
      );

      expect(jsonDecode(response.body), containsPair('user_code', 'ABCD-1234'));
      expect(outbound.single.bodyFields['client_id'], 'cid');
    });

    test('404s an unknown /github path', () async {
      expect((await http.get(url('/github/nope'))).statusCode, 404);
    });

    test('clears the stored token when handed an empty one', () async {
      await http.post(url('/github/auth/token'), body: 'ghp_stored');

      await http.post(url('/github/auth/token'), body: '');

      expect(jsonDecode((await http.get(url('/github/auth/status'))).body), {
        'configured': false,
      });
    });

    test('ignores an unreadable token file rather than failing', () async {
      // A directory where the token file should be: readToken must fall
      // through to "no token" instead of throwing out of every request.
      Directory(
        p.join(tempDir.path, 'config', 'sync_token'),
      ).createSync(recursive: true);

      expect(jsonDecode((await http.get(url('/github/auth/status'))).body), {
        'configured': false,
      });
    });

    test('passes a non-JSON device-flow response straight back', () async {
      canned['https://github.com/login/oauth/access_token'] = http.Response(
        '<html>rate limited</html>',
        200,
      );

      final response = await http.post(
        url('/github/auth/device/poll'),
        body: jsonEncode({'client_id': 'cid', 'device_code': 'dc'}),
      );

      expect(response.body, contains('rate limited'));
    });

    test('treats a malformed request body as empty fields', () async {
      final response = await http.post(
        url('/github/auth/device/start'),
        body: 'not json',
      );

      expect(response.statusCode, 200);
      expect(outbound.single.bodyFields['client_id'], 'null');
    });
  });
}
