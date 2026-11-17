/// The relay's REST node access against a recording mock server.
library;

import 'dart:convert';

import 'package:diet_guard_app/services/claude_relay_rtdb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late List<http.Request> seen;
  late http.Response Function(http.Request) answer;
  late RtdbNodes nodes;

  setUp(() {
    seen = [];
    answer = (_) => http.Response('null', 200);
    nodes = RtdbNodes(
      databaseUrl: 'https://db.example/',
      idToken: () async => 'TOKEN',
      client: MockClient((request) async {
        seen.add(request);
        return answer(request);
      }),
    );
  });

  test('reads go to <path>.json with the token and parse the JSON', () async {
    answer = (_) => http.Response('{"a":1}', 200);
    expect(await nodes.get('r/requests/X/result'), {'a': 1});
    expect(seen.single.url.path, '/r/requests/X/result.json');
    expect(seen.single.url.queryParameters['auth'], 'TOKEN');
  });

  test('keys are a shallow read', () async {
    answer = (_) => http.Response('{"req":true,"claim":true}', 200);
    expect(await nodes.keys('r/requests/X'), {'req', 'claim'});
    expect(seen.single.url.queryParameters['shallow'], 'true');
    answer = (_) => http.Response('null', 200);
    expect(await nodes.keys('r/requests/X'), isEmpty);
  });

  test(
    'put sends the unit as a JSON object, with the server timestamp',
    () async {
      await nodes.put('r/requests/X/req', {
        '_e2e': 'blob',
        'created': {'.sv': 'timestamp'},
      });
      expect(seen.single.method, 'PUT');
      expect(jsonDecode(seen.single.body), {
        '_e2e': 'blob',
        'created': {'.sv': 'timestamp'},
      });
    },
  );

  test('a refusal raises an error that never carries the token', () async {
    answer = (_) => http.Response('Permission denied', 401);
    await expectLater(
      nodes.get('r'),
      throwsA(
        isA<RelayTransportError>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('401'), isNot(contains('TOKEN'))),
        ),
      ),
    );
  });

  test('a network failure raises without the url', () async {
    final broken = RtdbNodes(
      databaseUrl: 'https://db.example',
      idToken: () async => 'TOKEN',
      client: MockClient((_) async => throw http.ClientException('boom')),
    );
    await expectLater(
      broken.delete('r'),
      throwsA(
        isA<RelayTransportError>().having(
          (e) => e.message,
          'message',
          isNot(contains('TOKEN')),
        ),
      ),
    );
  });

  group('deleteUnclaimed', () {
    test('deletes with the ETag it read', () async {
      answer = (request) => request.method == 'GET'
          ? http.Response('{"req":true}', 200, headers: {'etag': 'E1'})
          : http.Response('null', 200);
      expect(await nodes.deleteUnclaimed('r/requests/X'), isTrue);
      expect(seen.first.headers['X-Firebase-ETag'], 'true');
      expect(seen.last.method, 'DELETE');
      expect(seen.last.headers['if-match'], 'E1');
    });

    test('a claim or a result stops it before any delete', () async {
      for (final key in ['claim', 'result']) {
        seen.clear();
        answer = (_) => http.Response('{"req":true,"$key":true}', 200);
        expect(await nodes.deleteUnclaimed('r/requests/X'), isFalse);
        expect(seen.map((r) => r.method), ['GET']);
      }
    });

    test(
      'a claim that lands in between turns the delete into a refusal',
      () async {
        answer = (request) => request.method == 'GET'
            ? http.Response('{"req":true}', 200, headers: {'etag': 'E1'})
            : http.Response('ETag mismatch', 412);
        expect(await nodes.deleteUnclaimed('r/requests/X'), isFalse);
      },
    );

    test('a node already gone counts as withdrawn', () async {
      expect(await nodes.deleteUnclaimed('r/requests/X'), isTrue);
      expect(seen.map((r) => r.method), ['GET']);
    });
  });
}
