// The desktop wrapper is the other half of the web-build desktop app: it
// serves the assets, owns the on-disk mirror of the app's storage, and fronts
// GitHub. These tests drive it over a real loopback socket, since its
// contract is HTTP.
import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
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

  group('sync-account provisioning', () {
    /// Writes [files] into a temp config dir and restarts with the route on.
    Future<String> enableWith(Map<String, String> files) async {
      final configDir = Directory(p.join(tempDir.path, 'crdt-sync'))
        ..createSync(recursive: true);
      files.forEach((name, contents) {
        File(p.join(configDir.path, name)).writeAsStringSync(contents);
      });
      await server.stop();
      await startServer(serveSyncAccount: true, syncConfigDir: configDir.path);
      return 'http://localhost:${server.port}';
    }

    test('is 404 when not enabled', () async {
      // The default, and the whole security posture: a credential route must
      // not be reachable just because the wrapper is running.
      final response = await http.get(url(kSyncAccountPath));

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('serves the account when enabled', () async {
      final origin = await enableWith({
        'firebase.json': '{"email":"a@b.c"}',
        'password': 'pw\n',
      });

      final response = await http.get(Uri.parse('$origin$kSyncAccountPath'));
      final account = FirebaseAccount.tryParse(response.body);

      expect(response.statusCode, HttpStatus.ok);
      expect(account?.email, 'a@b.c');
      expect(account?.password, 'pw');
    });

    test('is 404 when the config files are absent', () async {
      final origin = await enableWith({});

      final response = await http.get(Uri.parse('$origin$kSyncAccountPath'));

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('is 404 when firebase.json has no usable email', () async {
      final origin = await enableWith({
        'firebase.json': '{"apiKey":"x"}',
        'password': 'pw',
      });

      final response = await http.get(Uri.parse('$origin$kSyncAccountPath'));

      expect(response.statusCode, HttpStatus.notFound);
    });
  });
}
