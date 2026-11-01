// The catering password rides in the export only as AEAD ciphertext under a
// random export key that the keyring syncs between devices.

import 'dart:convert';

import 'package:diet_guard_app/services/data_export.dart';
import 'package:diet_guard_app/services/data_export_kuchnia.dart';
import 'package:diet_guard_app/services/export_keyring_sync.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'body_test_support.dart';
import 'export_test_support.dart';

Future<void> _noPull() async {}

Future<Map<String, dynamic>> _root(MemorySecrets s) async =>
    jsonDecode(await exportAllData(keyring: s.keyring()))
        as Map<String, dynamic>;

Future<Object?> _importError(
  String text,
  MemorySecrets s, {
  Future<void> Function() pull = _noPull,
}) async {
  try {
    await importAllData(text, keyring: s.keyring(), pullKeys: pull);
  } on Object catch (error) {
    return error;
  }
  return null;
}

String _tamper(String export) {
  final root = jsonDecode(export) as Map<String, dynamic>;
  final box = root['kuchnia'] as Map<String, dynamic>;
  final bytes = base64Decode(box['ciphertext'] as String);
  bytes[0] ^= 0x01;
  box['ciphertext'] = base64Encode(bytes);
  return jsonEncode(root);
}

void main() {
  test('same device: login is restored into an empty local store', () async {
    final secrets = MemorySecrets();
    await bindFresh(kuchnia: (testMail, testPassword));
    final stamp = KuchniaCredentialService.editedAt;
    final file = await exportAllData(keyring: secrets.keyring());

    await bindFresh();
    expect(KuchniaCredentialService.isConfigured, isFalse);
    await importAllData(file, keyring: secrets.keyring(), pullKeys: _noPull);
    expect(KuchniaCredentialService.username, testMail);
    expect(KuchniaCredentialService.password, testPassword);
    expect(KuchniaCredentialService.editedAt, stamp);
  });

  test('envelope: v2 AES-256-GCM, kid, fresh nonce, no KDF', () async {
    final secrets = MemorySecrets();
    await bindFresh(kuchnia: (testMail, testPassword));
    final a = (await _root(secrets))['kuchnia'] as Map<String, dynamic>;
    final b = (await _root(secrets))['kuchnia'] as Map<String, dynamic>;
    expect(a['enc'], 'v2');
    expect(a['alg'], 'AES-256-GCM');
    expect(a['kid'], b['kid']);
    expect(a.containsKey('kdf'), isFalse);
    expect(base64Decode(a['nonce'] as String), hasLength(12));
    expect(a['nonce'], isNot(b['nonce']));
    expect(a['ciphertext'], isNot(b['ciphertext']));
    expect(secrets.data, hasLength(1));
  });

  test('export contains neither the plaintext login nor the key', () async {
    final secrets = MemorySecrets();
    await bindFresh(kuchnia: (testMail, testPassword));
    final file = await exportAllData(keyring: secrets.keyring());
    final key = (await secrets.keyring().ensureNewest()).bytes;
    expect(file, isNot(contains(testPassword)));
    expect(file, isNot(contains(testMail)));
    expect(file, isNot(contains(base64Encode(utf8.encode(testPassword)))));
    expect(file, isNot(contains(base64Encode(key))));
    expect(
      file,
      isNot(
        contains(key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()),
      ),
    );
  });

  test('second device imports after its keyring sync', () async {
    final remote = MemoryRemote();
    final a = MemorySecrets();
    final b = MemorySecrets();
    await bindFresh(kuchnia: (testMail, testPassword));
    await seedMeal('oats');
    final file = await exportAllData(keyring: a.keyring());
    await syncExportKeys(
      remote,
      keyring: a.keyring(),
      devicesDir: 'devs',
      deviceId: 'dev-a',
    );

    await bindFresh();
    var pulls = 0;
    await importAllData(
      file,
      keyring: b.keyring(),
      pullKeys: () async {
        pulls++;
        await syncExportKeys(
          remote,
          keyring: b.keyring(),
          devicesDir: 'devs',
          deviceId: 'dev-b',
        );
      },
    );
    expect(pulls, 1);
    expect(KuchniaCredentialService.password, testPassword);
    expect(await meals(), contains('oats'));
  });

  test('unknown kid: reported cleanly, rest still imports', () async {
    final a = MemorySecrets();
    await bindFresh(kuchnia: (testMail, testPassword));
    await seedMeal('soup');
    final file = await exportAllData(keyring: a.keyring());

    await bindFresh();
    final error = await _importError(file, MemorySecrets());
    expect(error, isA<KuchniaImportException>());
    expect(KuchniaCredentialService.isConfigured, isFalse);
    expect(await meals(), contains('soup'));
  });

  test('a failing key pull is the same clean failure', () async {
    final a = MemorySecrets();
    await bindFresh(kuchnia: (testMail, testPassword));
    final file = await exportAllData(keyring: a.keyring());
    await bindFresh();
    final error = await _importError(
      file,
      MemorySecrets(),
      pull: () async => throw StateError('offline'),
    );
    expect(error, isA<KuchniaImportException>());
  });

  test('tampered ciphertext is rejected, rest still imports', () async {
    final a = MemorySecrets();
    await bindFresh(kuchnia: (testMail, testPassword));
    await seedMeal('rice');
    final file = _tamper(await exportAllData(keyring: a.keyring()));

    await bindFresh();
    final error = await _importError(file, a);
    expect(error, isA<KuchniaImportException>());
    expect(KuchniaCredentialService.isConfigured, isFalse);
    expect(await meals(), contains('rice'));
  });

  test('keystore unavailable: kuchnia omitted and the skip recorded', () async {
    final secrets = MemorySecrets()..broken = true;
    await bindFresh(kuchnia: (testMail, testPassword));
    final file = await exportAllData(keyring: secrets.keyring());
    final root = jsonDecode(file) as Map<String, dynamic>;
    expect(root.containsKey('kuchnia'), isFalse);
    expect(root['kuchnia_skipped'], 'keystore_unavailable');
    expect(file, isNot(contains(testPassword)));
  });

  test('an existing local login is kept, never overwritten', () async {
    final a = MemorySecrets();
    await bindFresh(kuchnia: (testMail, testPassword));
    final file = await exportAllData(keyring: a.keyring());

    await bindFresh(kuchnia: ('other@example.pl', 'local-pw'));
    final stamp = KuchniaCredentialService.editedAt;
    await importAllData(file, keyring: a.keyring(), pullKeys: _noPull);
    expect(KuchniaCredentialService.username, 'other@example.pl');
    expect(KuchniaCredentialService.password, 'local-pw');
    expect(KuchniaCredentialService.editedAt, stamp);
  });

  test('no configured login: no box, no flag, no key minted', () async {
    final secrets = MemorySecrets();
    await bindFresh();
    final root = await _root(secrets);
    expect(root.containsKey('kuchnia'), isFalse);
    expect(root.containsKey('kuchnia_skipped'), isFalse);
    expect(secrets.data, isEmpty);
  });
}
