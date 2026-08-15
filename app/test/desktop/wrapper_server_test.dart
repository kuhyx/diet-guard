// The desktop wrapper is the other half of the web-build desktop app: it
// serves the assets, owns the on-disk mirror of the app's storage, and fronts
// GitHub. These tests drive it over a real loopback socket, since its
// contract is HTTP.
import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/desktop/github_proxy.dart';
import 'package:diet_guard_app/desktop/wrapper_server.dart';
import 'package:crdt_sync/crdt_sync.dart';
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

  group('static assets', () {
    test('serves index.html at the root', () async {
      final response = await http.get(url('/'));

      expect(response.statusCode, 200);
      expect(response.body, '<html>app</html>');
      expect(response.headers['content-type'], contains('text/html'));
    });

    test('serves .wasm as application/wasm', () async {
      // CanvasKit refuses any other content type and the app then renders
      // nothing at all -- the failure looks like a blank window, not an error.
      final response = await http.get(url('/main.wasm'));

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'application/wasm');
    });

    test('404s a missing asset', () async {
      expect((await http.get(url('/nope.js'))).statusCode, 404);
    });
  });
  group('document mirror', () {
    test('round-trips a document', () async {
      final posted = await http.post(
        url('/documents/food_log.json'),
        body: '{"2026-07-20":[]}',
      );
      final fetched = await http.get(url('/documents/food_log.json'));

      expect(posted.statusCode, 204);
      expect(fetched.body, '{"2026-07-20":[]}');
      expect(
        File(p.join(dataDir, 'documents', 'food_log.json')).readAsStringSync(),
        '{"2026-07-20":[]}',
      );
    });

    test('404s an unmirrored document', () async {
      expect(
        (await http.get(url('/documents/food_bank.json'))).statusCode,
        404,
      );
    });

    test('rejects a traversing name instead of writing outside dataDir', () {
      // The mirror writes into the user's home directory, so a `..` segment
      // would turn a document write into an arbitrary-file overwrite.
      expect(
        http
            .post(url('/documents/..%2F..%2Fevil'), body: 'x')
            .then((r) => r.statusCode),
        completion(400),
      );
    });

    test('rejects a method other than GET/POST', () async {
      expect((await http.delete(url('/documents/x.json'))).statusCode, 405);
    });
  });
  group('content types', () {
    test('labels each asset kind the browser is strict about', () {
      ContentType typeOf(String name) =>
          WrapperServer.contentTypeFor('/web/$name');

      expect(typeOf('main.dart.js').toString(), contains('text/javascript'));
      expect(typeOf('m.mjs').toString(), contains('text/javascript'));
      expect(typeOf('manifest.json').mimeType, 'application/json');
      expect(typeOf('style.css').toString(), contains('text/css'));
      expect(typeOf('icon.png').mimeType, 'image/png');
      expect(typeOf('photo.jpg').mimeType, 'image/jpeg');
      expect(typeOf('logo.svg').mimeType, 'image/svg+xml');
      expect(typeOf('f.ttf').mimeType, 'font/ttf');
      expect(typeOf('f.otf').mimeType, 'font/otf');
      expect(typeOf('f.woff2').mimeType, 'font/woff2');
      expect(typeOf('data.bin').mimeType, 'application/octet-stream');
    });
  });
}
