// The IndexedDB stores are the desktop device's primary copy of the food log
// and the *only* copy of its photos, and their wrapper-mirror fallback is the
// recovery path for a wiped Chrome profile. `idb_shim`'s in-memory backend
// lets all of that run on the plain VM, so none of it has to ship untested
// just because it only executes in a browser.
import 'dart:convert';
import 'dart:typed_data';

import 'package:diet_guard_app/services/blob_store_indexeddb.dart';
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

  group('IndexedDbBlobStore', () {
    late IndexedDbBlobStore store;

    setUp(() async {
      store = IndexedDbBlobStore(
        await _openMemoryDb(IndexedDbBlobStore.storeName),
        httpClient: wrapper.client,
      );
    });

    test('put returns a key ending in the extension and stores the bytes', () async {
      final key = await store.put('.jpg', Uint8List.fromList([1, 2, 3]));

      expect(key, endsWith('.jpg'));
      expect(await store.get(key), [1, 2, 3]);
    });

    test('put gives each photo its own key', () async {
      final first = await store.put('.jpg', Uint8List.fromList([1]));
      final second = await store.put('.jpg', Uint8List.fromList([1]));

      expect(first, isNot(second));
    });

    test('mirrors photo bytes to the wrapper', () async {
      // Photos never sync -- `imagePath` is stripped before push -- so this
      // mirror is the only thing standing between a cleared profile and
      // losing them permanently.
      final key = await store.put('.jpg', Uint8List.fromList([7, 7]));

      expect(wrapper.stored[key], [7, 7]);
    });

    test('recovers a photo from the wrapper when IndexedDB is empty', () async {
      wrapper.stored['photo.jpg'] = [4, 2];

      expect(await store.get('photo.jpg'), [4, 2]);
    });

    test('returns null for a photo neither side has', () async {
      expect(await store.get('gone.jpg'), null);
    });

    test('returns null when the wrapper is not running', () async {
      wrapper.offline = true;

      expect(await store.get('gone.jpg'), null);
    });
  });
}
