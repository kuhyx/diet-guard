// End-to-end encryption of the diet_guard sync tick (`sync_e2e.dart`).
//
// The fake GitHub stores what is PUT, so the header written on first use
// reads back and the sealed blobs are the bytes a real backend would hold.

import 'dart:convert';
import 'dart:io';

import 'package:crdt_sync/crdt_sync.dart' show E2eLockReason, RemoteStore;
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/export_keyring_default.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_e2e.dart';
import 'package:diet_guard_app/services/sync_merge.dart';
import 'package:diet_guard_app/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_secure_storage.dart';
import 'sync_service_test_support.dart';

const _new = 'diet-guard-sync/devices-e2e';
const _old = 'diet-guard-sync/devices';

String _text(Map<String, dynamic> put) =>
    utf8.decode(base64.decode(put['content'] as String));

void main() {
  late Directory tempDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    installFakeSecureStorage();
    tempDir = await Directory.systemTemp.createTemp('diet_guard_e2e_test_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    await AppSettingsService.initForTesting(FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(store: FileDocumentStore(tempDir));
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  test('the pushed food log holds no plaintext field', () async {
    await LogStorageService.instance.logMeal('secret oatmeal', manualNutrition);
    final fake = FakeGitHub();
    await runSync(fake.buildClient());

    final blob = _text(fake.putsByPath['$_new/phone/food_log.json']!);
    expect(blob, isNot(contains('secret')));
    expect(blob, isNot(contains('"fields"')));
    expect(blob, isNot(contains('kcal')));
    expect(await fake.opened('$_new/phone/food_log.json'), contains('secret'));
  });

  test('nothing is written to the old plaintext prefix or revs', () async {
    await LogStorageService.instance.logMeal('oatmeal', manualNutrition);
    final fake = FakeGitHub();
    await runSync(fake.buildClient());

    expect(fake.putsByPath, isNotEmpty);
    for (final path in fake.putsByPath.keys) {
      expect(path, isNot(startsWith('$_old/')));
      expect(path, isNot(startsWith('diet-guard-sync/revs/')));
    }
    expect(fake.putsByPath, contains('diet-guard-sync/revs-e2e/phone'));
  });

  test('export keys are pushed sealed, never to the old node', () async {
    await defaultKeyring().ensureNewest();
    final fake = FakeGitHub();
    await runSync(fake.buildClient());

    final sealed = fake.putsByPath['$_new/phone/export_keys.json'];
    expect(sealed, isNotNull);
    final opened = (await fake.opened('$_new/phone/export_keys.json'))!;
    final record = (jsonDecode(opened) as Map).values.single as Map;
    final keyB64 = ((record['fields'] as Map)['k'] as List).first as String;
    expect(_text(sealed!), isNot(contains(keyB64)));
    expect(fake.putsByPath, isNot(contains('$_old/phone/export_keys.json')));
  });

  test('an old plaintext peer log is copied, merged, and left alone', () async {
    await LogStorageService.instance.logMeal('peer porridge', manualNutrition);
    final local = await LogStorageService.instance.readLog();
    final peerLog = encodeLogForPush(dayLogToLog(local));
    await LogStorageService.instance.writeLog(const {});

    final fake = FakeGitHub(
      deviceDirs: const ['pc'],
      files: {'$_old/pc/food_log.json': peerLog},
    );
    final merged = await runSync(fake.buildClient());

    final descs = merged.values.expand((e) => e).map((e) => e.desc);
    expect(descs, contains('peer porridge'));
    expect(
      _text(fake.putsByPath['$_new/pc/food_log.json']!),
      isNot(contains('porridge')),
    );
    expect(fake.files['$_old/pc/food_log.json'], peerLog);
  });

  test('no passphrase: locked, nothing read or written', () async {
    installFakeSecureStorage(initial: const {'crdt_sync_e2e_passphrase': ''});
    final fake = FakeGitHub();
    await expectLater(
      runSync(fake.buildClient()),
      throwsA(isA<SyncLockedException>()),
    );
    expect(fake.puts, isEmpty);
    expect(syncLocked.value, isTrue);
    expect(
      const SyncLockedException(E2eLockReason.wrongKey).toString(),
      contains('wrongKey'),
    );
  });

  test('a wake-alarm transport failure skips only the weigh-ins', () async {
    await LogStorageService.instance.logMeal('oatmeal', manualNutrition);
    final fake = FakeGitHub();
    final store = _FailingPath(fake.buildClient(), 'wake-alarm-sync/e2e');

    await runSync(store);

    expect(fake.putsByPath, contains('$_new/phone/food_log.json'));
    expect(await openWakeAlarmStore(store), isNull);
  });
}

/// Delegates to [inner] but fails every read of [path].
class _FailingPath implements RemoteStore {
  _FailingPath(this.inner, this.path);

  final RemoteStore inner;
  final String path;

  @override
  Future<String?> getFileText(String p) =>
      p == path ? Future.error(Exception('down')) : inner.getFileText(p);

  @override
  Future<List<String>> listDirectory(String p) => inner.listDirectory(p);

  @override
  Future<void> putFileText(String p, String text, {required String message}) =>
      inner.putFileText(p, text, message: message);

  @override
  Future<void> deleteFile(String p, {String message = ''}) =>
      inner.deleteFile(p, message: message);

  @override
  Future<bool> canAccessRemote() => inner.canAccessRemote();

  @override
  void close() => inner.close();
}
