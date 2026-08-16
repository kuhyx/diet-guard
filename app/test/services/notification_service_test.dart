import 'package:diet_guard_app/services/notification_backend_io.dart';
import 'package:diet_guard_app/services/notification_service.dart';
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

    test('syncToSlots shows due slots and cancels the rest', () async {
      final log = installFakeAndroidNotifications();
      NotificationService.resetForTesting(
        backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
      );
      await NotificationService.init();
      log.clear();

      await NotificationService.instance.syncToSlots([12, 20]);

      final shown = log
          .where((c) => c.method == 'show')
          .map((c) => (c.arguments as Map)['id'])
          .toSet();
      final cancelled = log
          .where((c) => c.method == 'cancel')
          .map((c) => (c.arguments as Map)['id'])
          .toSet();
      expect(shown, {12, 20});
      // Every other id in the 0..23 space is cancelled, not just the other
      // slots of the current schedule -- see syncToSlots' comment.
      expect(cancelled, containsAll(<int>{8, 16}));
      expect(cancelled.intersection(shown), isEmpty);
    });

    test('syncToSlots with no due slots cancels every id in the day', () async {
      final log = installFakeAndroidNotifications();
      NotificationService.resetForTesting(
        backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
      );
      await NotificationService.init();
      log.clear();

      await NotificationService.instance.syncToSlots(const []);

      expect(log.where((c) => c.method == 'show'), isEmpty);
      // 24, not 4: the slot hour doubles as the notification id, so a
      // schedule change would otherwise orphan the ids it no longer contains.
      expect(log.where((c) => c.method == 'cancel'), hasLength(24));
    });

    test('syncToSlots cancels ids orphaned by a schedule change', () async {
      // The regression this guards: the slot hour *is* the notification id,
      // and syncToSlots used to iterate only the current schedule's slots.
      // Switching 08/12/16/20 -> 08/11/14/17/20 therefore left ids 12 and 16
      // posted with nothing that would ever cancel them, so the phone nagged
      // forever about checkpoints that no longer existed.
      final log = installFakeAndroidNotifications();
      NotificationService.resetForTesting(
        backend: LocalNotificationsBackend(FlutterLocalNotificationsPlugin()),
      );
      await NotificationService.init();

      // Due under the old four-meal schedule.
      await NotificationService.instance.syncToSlots([12, 16]);
      log.clear();
      // Now due under a five-meal schedule, which has neither 12 nor 16.
      await NotificationService.instance.syncToSlots([11]);

      final cancelled = log
          .where((c) => c.method == 'cancel')
          .map((c) => (c.arguments as Map)['id'])
          .toSet();
      expect(cancelled, containsAll(<int>{12, 16}));
    });

    test(
      'syncToSlots cancels a slot whose meal was logged after it fired',
      () async {
        final log = installFakeAndroidNotifications();
        NotificationService.resetForTesting(
          backend: LocalNotificationsBackend(
            FlutterLocalNotificationsPlugin(),
          ),
        );
        await NotificationService.init();

        await NotificationService.instance.syncToSlots([12]);
        log.clear();
        await NotificationService.instance.syncToSlots(const []); // logged

        expect(
          log
              .where((c) => c.method == 'cancel')
              .map((c) => (c.arguments as Map)['id']),
          contains(12),
        );
      },
    );
  });

  test('instance throws before init has ever been called', () {
    expect(() => NotificationService.instance, throwsA(anything));
  });
}
