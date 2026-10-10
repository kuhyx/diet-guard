import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/services/notification_backend.dart';
import 'package:diet_guard_app/services/notification_backend_io.dart';
import 'package:diet_guard_app/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(NotificationService.resetForTesting);

  group('on Android', () {
    test('init constructs the real plugin singleton on first use', () async {
      final log = installFakeAndroidNotifications();
      NotificationService.resetForTesting(); // no _instance yet

      await NotificationService.init();

      expect(log.where((c) => c.method == 'initialize'), hasLength(1));
    });

    test('init calls the platform initialize method, idempotently', () async {
      final log = installFakeAndroidNotifications();
      NotificationService.resetForTesting(
        backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
      );

      await NotificationService.init();
      await NotificationService.init(); // second call must be a no-op

      expect(log.where((c) => c.method == 'initialize'), hasLength(1));
    });

    test('requestPermission delegates to the Android implementation', () async {
      installFakeAndroidNotifications();
      NotificationService.resetForTesting(
        backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
      );
      await NotificationService.init();

      expect(await NotificationService.instance.requestPermission(), isTrue);
    });

    Future<List<MethodCall>> ready({Map<int, String>? active}) async {
      final log = installFakeAndroidNotifications(active: active);
      NotificationService.resetForTesting(
        backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
      );
      await NotificationService.init();
      log.clear();
      return log;
    }

    Set<Object?> ids(List<MethodCall> log, String method) => {
      for (final call in log)
        if (call.method == method) (call.arguments as Map)['id'],
    };

    test('syncToSlots shows due slots and cancels other reminders', () async {
      final log = await ready(
        active: {480: reminderChannelId, 720: reminderChannelId},
      );

      await NotificationService.instance.syncToSlots([720, 1200]);

      expect(ids(log, 'show'), {720, 1200});
      expect(ids(log, 'cancel'), {480});
    });

    test('a quiet tick costs one lookup and no cancels', () async {
      // The cost bound: the old design swept every id each tick, which at
      // minute resolution would be 1440 platform calls per background run.
      final log = await ready();

      await NotificationService.instance.syncToSlots(const []);

      expect(log.map((c) => c.method), ['getActiveNotifications']);
    });

    test('the upgrade cancels reminders keyed by the old slot hours', () async {
      // Older builds used the slot *hour* as the id. Nothing in the minute
      // schedule names 8/12/16, so only the active lookup can find them.
      final log = await ready(
        active: {
          8: reminderChannelId,
          12: reminderChannelId,
          16: reminderChannelId,
        },
      );

      await NotificationService.instance.syncToSlots([720]);

      expect(ids(log, 'cancel'), {8, 12, 16});
      expect(ids(log, 'show'), {720});
    });

    test('syncToSlots cancels ids orphaned by a schedule change', () async {
      // The regression this guards: the slot minute *is* the notification
      // id, so iterating only the current schedule's slots would leave the
      // old schedule's reminders posted forever.
      final log = await ready();
      await NotificationService.instance.syncToSlots([720, 960]);
      log.clear();

      // Now due under a schedule that has neither 720 nor 960.
      await NotificationService.instance.syncToSlots([660]);

      expect(ids(log, 'cancel'), {720, 960});
    });

    test('leaves notifications on other channels alone', () async {
      final log = await ready(active: {5: 'some_other_channel'});

      await NotificationService.instance.syncToSlots(const []);

      expect(ids(log, 'cancel'), isEmpty);
    });

    test(
      'syncToSlots cancels a slot whose meal was logged after it fired',
      () async {
        final log = await ready();
        await NotificationService.instance.syncToSlots([720]);
        log.clear();
        await NotificationService.instance.syncToSlots(const []); // logged

        expect(ids(log, 'cancel'), {720});
      },
    );
  });

  test('a failed active lookup falls back to sweeping every id', () async {
    final backend = _FakeBackend()..failLookup = true;
    NotificationService.resetForTesting(backend: backend);
    await NotificationService.init();

    await NotificationService.instance.syncToSlots([435]);

    expect(backend.shown, [435]);
    expect(backend.cancelled, hasLength(kMinutesPerDay - 1));
    expect(backend.cancelled, isNot(contains(435)));
    expect(backend.cancelled, containsAll(<int>[0, 8, 23, 720, 1439]));
  });

  test('instance throws before init has ever been called', () {
    expect(() => NotificationService.instance, throwsA(anything));
  });
}

/// A platform-free backend for the paths the channel fake cannot reach.
class _FakeBackend implements NotificationBackend {
  bool failLookup = false;
  final shown = <int>[];
  final cancelled = <int>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<bool?> requestPermission() async => null;

  @override
  Future<void> show(int slot, String title, String body) async =>
      shown.add(slot);

  @override
  Future<void> cancel(int slot) async => cancelled.add(slot);

  @override
  Future<Set<int>> activeIds() async {
    if (failLookup) throw StateError('no notification service');
    return {};
  }
}
