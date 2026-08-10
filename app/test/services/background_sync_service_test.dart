// `backgroundSyncPush` is the unit-testable half of the connectivity-gated
// WorkManager backstop; the dispatcher branch and the one-off registration
// itself are integration-only (real WorkManager isolate, on-device smoke
// test) and excluded from coverage, exactly like the periodic check.

import 'dart:io';

import 'package:diet_guard_app/services/document_store_io.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/background_sync_service.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/services/sync_device_id.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fake_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('diet_guard_bg_sync_');
    LogStorageService.resetForTesting(store: FileDocumentStore(tempDir));
    FoodBankService.resetForTesting(store: FileDocumentStore(tempDir));
    // Pre-seeds the singleton so backgroundSyncPush's own AppSettingsService
    // .init() call short-circuits instead of hitting the real (unmocked in
    // this test) path_provider channel.
    AppSettingsService.resetForTesting(store: FileDocumentStore(tempDir));
    BudgetHistoryService.resetForTesting(
      store: FileDocumentStore(tempDir),
    );
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
    AppSettingsService.resetForTesting();
    BudgetHistoryService.resetForTesting();
    await tempDir.delete(recursive: true);
  });

  test('does nothing and does not retry when sync is unconfigured', () async {
    SharedPreferences.setMockInitialValues({});
    installFakeSecureStorage();
    var puts = 0;
    final mock = MockClient((req) async {
      if (req.method == 'PUT') puts++;
      return http.Response('', 404);
    });

    final ok = await backgroundSyncPush(httpClient: mock);

    expect(ok, isTrue); // nothing to do -> success, no retry
    expect(puts, 0);
  });

  test('pushes and reports success when configured', () async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    var puts = 0;
    final mock = MockClient((req) async {
      if (req.method == 'PUT') {
        puts++;
        return http.Response('{}', 200); // Contents-API PUT succeeded
      }
      // Bare `/repos/<owner>/<repo>` GET is the repo-exists probe.
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404);
    });

    final ok = await backgroundSyncPush(httpClient: mock);

    expect(ok, isTrue);
    // syncLog always pushes, even an empty merged result: food_log.json,
    // budget.json, food_bank.json, food_bank_manual.json.
    // Four data files plus this device's revision, which is what lets a
    // later tick skip an unchanged peer.
    expect(puts, 5);
  });

  test('pushes under the persisted uuid, not the legacy role id', () async {
    // Regression guard. A WorkManager background isolate has its own static state,
    // so without initSyncDeviceId() here `currentSyncDeviceId` falls back to
    // the compile-time 'phone' constant and this tick writes to
    // `devices/phone/`. That splits the device across two directories, and
    // since sync_state holds a single `pushedRev` with no notion of which
    // identity wrote it, the next *foreground* push then sees `unchanged`
    // and skips writing the uuid directory at all.
    const uuid = '77e39198-ff83-479b-a905-b0cd68b66094';
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
      'crdt.nodeId': uuid,
    });
    resetSyncDeviceIdForTest();
    installFakeSecureStorage(initial: {'sync.token': 't'});
    final pushedPaths = <String>[];
    final mock = MockClient((req) async {
      if (req.method == 'PUT') {
        pushedPaths.add(req.url.path);
        return http.Response('{}', 200);
      }
      if (req.method == 'GET' && req.url.pathSegments.length == 3) {
        return http.Response('{}', 200);
      }
      return http.Response('', 404);
    });

    await backgroundSyncPush(httpClient: mock);

    expect(pushedPaths, isNotEmpty);
    expect(pushedPaths.every((path) => path.contains(uuid)), isTrue);
    expect(pushedPaths.any((path) => path.contains('/devices/phone/')), isFalse);
  });

  test('reports failure (retry) when the push errors', () async {
    SharedPreferences.setMockInitialValues({
      'sync.owner': 'o',
      'sync.repo': 'r',
    });
    installFakeSecureStorage(initial: {'sync.token': 't'});
    final mock = MockClient((_) async => http.Response('boom', 500));

    final ok = await backgroundSyncPush(httpClient: mock);

    expect(ok, isFalse); // transient -> WorkManager should retry
  });
}
