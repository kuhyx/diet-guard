// The IndexedDB document store is the desktop device's primary copy of the
// food log, and its wrapper-mirror fallback is the recovery path for a wiped
// Chrome profile. `idb_shim`'s in-memory backend lets all of that run on the
// plain VM, so none of it has to ship untested just because it only executes
// in a browser.
import 'dart:convert';

import 'package:diet_guard_app/services/desktop_wrapper.dart';
import 'package:diet_guard_app/services/document_store_indexeddb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idb_shim/idb_shim.dart';

/// Stands in for the desktop wrapper: records what was mirrored to it and
/// serves back whatever it has been seeded with.
class _FakeWrapper {
  final Map<String, List<int>> stored = {};
  var offline = false;

  http.Client get client => MockClient((request) async {
    if (offline) throw http.ClientException('no wrapper running');
    final name = request.url.pathSegments.last;
    if (request.method == 'POST') {
      stored[name] = request.bodyBytes;
      return http.Response('', 204);
    }
    final body = stored[name];
    if (body == null) return http.Response('', 404);
    return http.Response.bytes(body, 200);
  });
}

Future<Database> _openMemoryDb(String store) => newIdbFactoryMemory().open(
  'test',
  version: 1,
  onUpgradeNeeded: (event) => event.database.createObjectStore(store),
);

void main() {
  late _FakeWrapper wrapper;

  setUp(() => wrapper = _FakeWrapper());

  group('IndexedDbDocumentStore', () {
    late IndexedDbDocumentStore store;

    setUp(() async {
      store = IndexedDbDocumentStore(
        await _openMemoryDb(IndexedDbDocumentStore.storeName),
        httpClient: wrapper.client,
      );
    });

    test('round-trips a document', () async {
      await store.write('food_log.json', '{"2026-07-20":[]}');

      expect(await store.read('food_log.json'), '{"2026-07-20":[]}');
    });

    test('mirrors every write to the wrapper', () async {
      // The mirror is what makes a wiped Chrome profile recoverable, so a
      // write that only reaches IndexedDB is a silent data-loss risk.
      await store.write('food_log.json', '{"a":1}');

      expect(utf8.decode(wrapper.stored['food_log.json']!), '{"a":1}');
    });

    test('recovers from the wrapper when IndexedDB is empty', () async {
      // Exactly the cleared-profile case: nothing local, everything on disk.
      wrapper.stored['food_log.json'] = utf8.encode('{"recovered":true}');

      expect(await store.read('food_log.json'), '{"recovered":true}');
    });

    test('returns null when neither side has the document', () async {
      expect(await store.read('food_bank.json'), null);
    });

    test('returns null when the wrapper is not running', () async {
      // Opened as a plain browser tab: no wrapper, no mirror, still usable.
      wrapper.offline = true;

      expect(await store.read('food_log.json'), null);
    });

    test('a write still succeeds with no wrapper running', () async {
      wrapper.offline = true;

      await store.write('food_log.json', '{"a":1}');

      expect(await store.read('food_log.json'), '{"a":1}');
    });
  });
}
