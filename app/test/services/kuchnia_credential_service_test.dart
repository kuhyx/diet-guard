/// The catering credential's local storage.
///
/// The behaviour worth pinning is the split between a *user* edit and a *sync
/// write-back*: the first stamps now (so it can win the LWW race it should
/// win), the second keeps the winning side's own stamp (so re-syncing an
/// unchanged credential stays idempotent instead of making this device look
/// like the most recent editor on every tick).
library;

import 'dart:convert';

import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/kuchnia_credential_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory store, so these tests need no plugin channel.
class _MemoryStore implements DocumentStore {
  final Map<String, String> documents = {};
  int writes = 0;

  @override
  Future<String?> read(String name) async => documents[name];

  @override
  Future<void> write(String name, String contents) async {
    documents[name] = contents;
    writes++;
  }
}

void main() {
  late _MemoryStore store;

  setUp(() {
    store = _MemoryStore();
    KuchniaCredentialService.resetForTesting();
  });

  tearDown(KuchniaCredentialService.resetForTesting);

  test('reads back nothing before anything is stored', () async {
    await KuchniaCredentialService.initForTesting(store);
    expect(KuchniaCredentialService.username, isEmpty);
    expect(KuchniaCredentialService.password, isEmpty);
    expect(KuchniaCredentialService.isConfigured, isFalse);
  });

  test('a user edit round-trips and stamps a time', () async {
    await KuchniaCredentialService.initForTesting(store);
    await KuchniaCredentialService.instance.save('me@example.com', 'hunter2');

    expect(KuchniaCredentialService.username, 'me@example.com');
    expect(KuchniaCredentialService.password, 'hunter2');
    expect(KuchniaCredentialService.editedAt, isNotEmpty);
    expect(KuchniaCredentialService.isConfigured, isTrue);
  });

  test('a stored credential survives a reload', () async {
    await KuchniaCredentialService.initForTesting(store);
    await KuchniaCredentialService.instance.save('me@example.com', 'hunter2');

    KuchniaCredentialService.resetForTesting();
    await KuchniaCredentialService.initForTesting(store);
    expect(KuchniaCredentialService.username, 'me@example.com');
    expect(KuchniaCredentialService.password, 'hunter2');
  });

  test('the username is trimmed but the password is not', () async {
    // A pasted e-mail often carries whitespace; a password's whitespace may be
    // load-bearing, so trimming it would lock the user out of their own panel.
    await KuchniaCredentialService.initForTesting(store);
    await KuchniaCredentialService.instance.save('  me@example.com  ', ' pw ');

    expect(KuchniaCredentialService.username, 'me@example.com');
    expect(KuchniaCredentialService.password, ' pw ');
  });

  test('a sync write-back keeps the winning edit time', () async {
    await KuchniaCredentialService.initForTesting(store);
    await KuchniaCredentialService.instance.applySynced(
      'peer@example.com',
      'peer-pass',
      '2026-08-20T09:00:00.000',
    );
    expect(KuchniaCredentialService.editedAt, '2026-08-20T09:00:00.000');
  });

  test('an unchanged sync write-back does not rewrite the document', () async {
    // Otherwise every tick looks like an edit and republishes to every peer.
    await KuchniaCredentialService.initForTesting(store);
    await KuchniaCredentialService.instance.applySynced(
      'peer@example.com',
      'peer-pass',
      '2026-08-20T09:00:00.000',
    );
    final writesAfterFirst = store.writes;

    await KuchniaCredentialService.instance.applySynced(
      'peer@example.com',
      'peer-pass',
      '2026-08-20T09:00:00.000',
    );
    expect(store.writes, writesAfterFirst);
  });

  test('a corrupt document reads back as not configured', () async {
    store.documents[KuchniaCredentialService.documentName] = '{not json';
    await KuchniaCredentialService.initForTesting(store);
    expect(KuchniaCredentialService.isConfigured, isFalse);
  });

  test('a non-object document reads back as not configured', () async {
    store.documents[KuchniaCredentialService.documentName] = '[1, 2]';
    await KuchniaCredentialService.initForTesting(store);
    expect(KuchniaCredentialService.isConfigured, isFalse);
  });

  test('wrongly typed halves read back as not configured', () async {
    store.documents[KuchniaCredentialService.documentName] = jsonEncode({
      'username': 'me@example.com',
      'password': 42,
    });
    await KuchniaCredentialService.initForTesting(store);
    expect(KuchniaCredentialService.password, isEmpty);
    expect(KuchniaCredentialService.isConfigured, isFalse);
  });

  test('static getters are safe before init', () {
    // Widget tests never initialise this service, and reading it must not
    // throw for them.
    expect(KuchniaCredentialService.username, isEmpty);
    expect(KuchniaCredentialService.isConfigured, isFalse);
    expect(KuchniaCredentialService.isInitialized, isFalse);
  });
}
