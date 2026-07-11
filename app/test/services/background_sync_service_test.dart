// `backgroundSyncPush` is the unit-testable half of the connectivity-gated
// WorkManager backstop; the dispatcher branch and the one-off registration
// itself are integration-only (real WorkManager isolate, on-device smoke
// test) and excluded from coverage, exactly like the periodic check.

import 'dart:io';

import 'package:diet_guard_app/services/background_sync_service.dart';
import 'package:diet_guard_app/services/foodbank_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
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
    LogStorageService.resetForTesting(testDir: tempDir);
    FoodBankService.resetForTesting(testDir: tempDir);
  });

  tearDown(() async {
    LogStorageService.resetForTesting();
    FoodBankService.resetForTesting();
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
    expect(puts, 1);
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
