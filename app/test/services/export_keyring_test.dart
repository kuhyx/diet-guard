// The export keyring: a never-overwritten set of random keys that syncs.

import 'package:diet_guard_app/services/export_keyring.dart';
import 'package:diet_guard_app/services/export_keyring_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_test_support.dart';
import 'export_test_support.dart';

void main() {
  test(
    'a key is generated once, 256-bit, and persisted in the keystore',
    () async {
      final secrets = MemorySecrets();
      final first = await secrets.keyring().ensureNewest();
      final again = await secrets.keyring().ensureNewest();
      expect(first.bytes, hasLength(32));
      expect(first.kid, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(again.kid, first.kid);
      expect(again.bytes, first.bytes);
      expect(secrets.data, hasLength(1));
    },
  );

  test(
    'two devices generate concurrently: both keys survive the merge',
    () async {
      final remote = MemoryRemote();
      final a = MemorySecrets();
      final b = MemorySecrets();
      final keyA = await a.keyring().ensureNewest();
      final keyB = await b.keyring().ensureNewest();
      expect(keyA.kid, isNot(keyB.kid));

      for (final (id, secrets) in [('dev-a', a), ('dev-b', b), ('dev-a', a)]) {
        await syncExportKeys(
          remote,
          keyring: secrets.keyring(),
          devicesDir: 'devs',
          deviceId: id,
        );
      }
      for (final secrets in [a, b]) {
        final keys = {for (final k in await secrets.keyring().all()) k.kid: k};
        expect(keys.keys, containsAll([keyA.kid, keyB.kid]));
        expect(keys[keyA.kid]!.bytes, keyA.bytes);
        expect(keys[keyB.kid]!.bytes, keyB.bytes);
      }
    },
  );

  test(
    'a synced record never replaces a key already held under its id',
    () async {
      final secrets = MemorySecrets();
      final mine = await secrets.keyring().ensureNewest();
      final other = MemorySecrets();
      await other.keyring().mergeKeys([
        ExportKey(mine.kid, List.filled(32, 7), DateTime.utc(2030)),
      ]);
      await secrets.keyring().mergeKeys(await other.keyring().all());
      expect((await secrets.keyring().byId(mine.kid))!.bytes, mine.bytes);
    },
  );

  test('malformed synced keys are ignored', () async {
    final secrets = MemorySecrets();
    await secrets.keyring().mergeKeys([
      ExportKey('not-a-kid', List.filled(32, 1), DateTime.utc(2030)),
      ExportKey('0123456789abcdef', List.filled(5, 1), DateTime.utc(2030)),
    ]);
    expect(await secrets.keyring().all(), isEmpty);
  });

  test('the newest local key is the one used for export', () async {
    final secrets = MemorySecrets();
    final ring = secrets.keyring();
    await ring.mergeKeys([
      ExportKey('aaaaaaaaaaaaaaaa', List.filled(32, 1), DateTime.utc(2026)),
      ExportKey('bbbbbbbbbbbbbbbb', List.filled(32, 2), DateTime.utc(2027)),
    ]);
    expect((await ring.ensureNewest()).kid, 'bbbbbbbbbbbbbbbb');
  });
}
