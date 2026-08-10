import 'package:diet_guard_app/services/sync_health.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SyncHealthStatus.isStalled', () {
    test('a device that has never synced is not flagged', () {
      // A fresh install with no account yet is normal, not a fault; nagging
      // there would train the banner to be ignored.
      final fresh = SyncHealthStatus(
        lastSuccess: null,
        failureKind: null,
        now: DateTime(2026, 8, 10),
      );
      expect(fresh.isStalled, isFalse);
      expect(fresh.message, isNull);
    });

    test('a recent success is healthy', () {
      final now = DateTime(2026, 8, 10, 12);
      final status = SyncHealthStatus(
        lastSuccess: now.subtract(const Duration(minutes: 30)),
        failureKind: null,
        now: now,
      );
      expect(status.isStalled, isFalse);
    });

    test('a success older than the staleness window is flagged', () {
      final now = DateTime(2026, 8, 10, 12);
      final status = SyncHealthStatus(
        lastSuccess: now.subtract(kSyncStaleAfter + const Duration(hours: 1)),
        failureKind: null,
        now: now,
      );
      expect(status.isStalled, isTrue);
      expect(status.message, contains('Not syncing since'));
    });

    test('an outright failure is flagged even when recent', () {
      final now = DateTime(2026, 8, 10, 12);
      final status = SyncHealthStatus(
        lastSuccess: now.subtract(const Duration(minutes: 1)),
        failureKind: SyncFailureKind.failed,
        now: now,
      );
      expect(status.isStalled, isTrue);
    });

    test('an unconfigured device names the missing account', () {
      final now = DateTime(2026, 8, 10, 12);
      final status = SyncHealthStatus(
        lastSuccess: now.subtract(const Duration(days: 2)),
        failureKind: SyncFailureKind.unconfigured,
        now: now,
      );
      expect(status.message, contains('no account connected'));
    });

    test('reports days for a long stall and hours for a short one', () {
      final now = DateTime(2026, 8, 10, 12);
      String? messageAfter(Duration since) => SyncHealthStatus(
        lastSuccess: now.subtract(since),
        failureKind: null,
        now: now,
      ).message;

      expect(messageAfter(const Duration(days: 3)), contains('3d ago'));
      expect(messageAfter(const Duration(hours: 9)), contains('9h ago'));
    });

    test('a failure just after a success does not say "0h ago"', () {
      // Regression guard: reporting elapsed time before any has elapsed
      // rendered "Not syncing since 0h ago", which reads as a bug in the
      // banner rather than a report about the sync.
      final now = DateTime(2026, 8, 10, 12);
      final status = SyncHealthStatus(
        lastSuccess: now.subtract(const Duration(minutes: 5)),
        failureKind: SyncFailureKind.failed,
        now: now,
      );
      expect(status.isStalled, isTrue);
      expect(status.message, 'Not syncing. Meals stay on this device.');
      expect(status.message, isNot(contains('0h')));
    });

    test('a failure with no prior success still reads sensibly', () {
      final status = SyncHealthStatus(
        lastSuccess: null,
        failureKind: SyncFailureKind.failed,
        now: DateTime(2026, 8, 10),
      );
      expect(status.message, 'Not syncing. Meals stay on this device.');
    });
  });

  group('SyncHealth persistence', () {
    test('recordSuccess clears a previous failure', () async {
      await SyncHealth.recordFailure();
      expect((await SyncHealth.read()).failureKind, SyncFailureKind.failed);

      await SyncHealth.recordSuccess();
      final status = await SyncHealth.read();
      expect(status.failureKind, isNull);
      expect(status.lastSuccess, isNotNull);
      expect(status.isStalled, isFalse);
    });

    test('recordUnconfigured round-trips', () async {
      await SyncHealth.recordUnconfigured();
      expect(
        (await SyncHealth.read()).failureKind,
        SyncFailureKind.unconfigured,
      );
    });

    test('an unrecognised stored kind reads as no failure', () async {
      SharedPreferences.setMockInitialValues({
        'sync.health.failureKind': 'not-a-kind',
      });
      expect((await SyncHealth.read()).failureKind, isNull);
    });

    test('resetForTest forgets everything', () async {
      await SyncHealth.recordSuccess();
      await SyncHealth.resetForTest();
      final status = await SyncHealth.read();
      expect(status.lastSuccess, isNull);
      expect(status.failureKind, isNull);
    });
  });
}
