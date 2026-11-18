import 'package:crdt_sync_flutter/crdt_sync_flutter.dart'
    show AppErrors, AppErrorsConfig, ErrorQueue;
import 'package:diet_guard_app/services/sync_attempt.dart';
import 'package:diet_guard_app/services/sync_health.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = AppErrorsConfig(
  app: 'diet-guard',
  repo: 'kuhyx/diet-guard',
  package: 'diet_guard_app',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ErrorQueue queue;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    queue = await ErrorQueue.open(await SharedPreferences.getInstance());
    AppErrors.instance = AppErrors.forTest(_config, queue);
  });

  tearDown(() => AppErrors.instance = null);

  test('a sync that lands records success and reports nothing', () async {
    expect(await attemptSync(() async {}), isTrue);
    final status = await SyncHealth.read();
    expect(status.lastSuccess, isNotNull);
    expect(status.failureKind, isNull);
    expect(queue.entries, isEmpty);
  });

  test('a failed sync records the failure and files its cause', () async {
    final ok = await attemptSync(() async => throw StateError('locked'));
    expect(ok, isFalse);
    final status = await SyncHealth.read();
    expect(status.failureKind, SyncFailureKind.failed);
    final entry = queue.entries.single;
    expect(entry.kind, 'sync.failed');
    expect(entry.error, contains('locked'));
  });

  test('without installed reporting a failure is still recorded', () async {
    AppErrors.instance = null;
    expect(await attemptSync(() async => throw StateError('x')), isFalse);
    expect((await SyncHealth.read()).failureKind, SyncFailureKind.failed);
  });

  test('a later success clears the failure (the banner goes away)', () async {
    await attemptSync(() async => throw StateError('offline'));
    await attemptSync(() async {});
    final status = await SyncHealth.read();
    expect(status.failureKind, isNull);
    expect(status.message, isNull);
  });
}
