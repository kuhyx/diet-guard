// Guard: whatever the desktop wrapper answers with an error status reaches
// the Chrome --app window as a status code with an EMPTY body -- never an
// error sentence painted in place of the app. Terminal stderr lines (the
// launcher's own log) are not covered: they are terminal text and stay.
import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart';
import 'package:diet_guard_app/desktop/github_proxy.dart';
import 'package:diet_guard_app/desktop/wrapper_server.dart';
import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late WrapperServer server;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_no_text_');
    final webRoot = p.join(tempDir.path, 'web');
    final dataDir = p.join(tempDir.path, 'data');
    await Directory(webRoot).create(recursive: true);
    File(p.join(webRoot, 'index.html')).writeAsStringSync('<html></html>');
    // A FILE where the documents directory belongs: a POST then throws
    // inside the handler, which is the wrapper's 500 path.
    await Directory(dataDir).create(recursive: true);
    File(p.join(dataDir, 'documents')).writeAsStringSync('');
    server = WrapperServer(
      webRoot: webRoot,
      dataDir: dataDir,
      gitHubProxy: GitHubProxy(
        tokenPath: p.join(tempDir.path, 'sync_token'),
        fallbackTokenPath: p.join(tempDir.path, 'fallback_token'),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
    );
    await server.start(0);
  });

  tearDown(() async {
    await server.stop();
    await tempDir.delete(recursive: true);
  });

  Uri url(String path) => Uri.parse('http://localhost:${server.port}$path');

  // (method, path, expected status): every error route the wrapper owns.
  final cases = <(String, String, int)>[
    ('GET', '/missing.js', HttpStatus.notFound),
    ('GET', '/github/nope', HttpStatus.notFound),
    ('GET', WrapperPaths.documents, HttpStatus.badRequest),
    ('PUT', '${WrapperPaths.documents}log.json', HttpStatus.methodNotAllowed),
    ('GET', '${WrapperPaths.documents}absent.json', HttpStatus.notFound),
    ('GET', kSyncAccountPath, HttpStatus.notFound),
    (
      'POST',
      '${WrapperPaths.documents}log.json',
      HttpStatus.internalServerError,
    ),
  ];

  for (final (method, path, status) in cases) {
    test('$method $path answers $status with an empty body', () async {
      final response = await http.Response.fromStream(
        await http.Client().send(http.Request(method, url(path))),
      );
      expect(response.statusCode, status);
      expect(response.body, isEmpty, reason: 'nothing painted in the window');
    });
  }
}
