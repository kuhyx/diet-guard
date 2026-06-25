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
        plugin: FlutterLocalNotificationsPlugin(),
      );

      await NotificationService.init();
      await NotificationService.init(); // second call must be a no-op

      expect(log.where((c) => c.method == 'initialize'), hasLength(1));
    });

    test('requestPermission delegates to the Android implementation', () async {
      installFakeAndroidNotifications();
      NotificationService.resetForTesting(
        plugin: FlutterLocalNotificationsPlugin(),
      );
      await NotificationService.init();

      expect(await NotificationService.instance.requestPermission(), isTrue);
    });

    test('syncToSlots shows due slots and cancels the rest', () async {
      final log = installFakeAndroidNotifications();
      NotificationService.resetForTesting(
        plugin: FlutterLocalNotificationsPlugin(),
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
      expect(cancelled, {8, 16});
    });

    test('syncToSlots with no due slots cancels every known slot', () async {
      final log = installFakeAndroidNotifications();
      NotificationService.resetForTesting(
        plugin: FlutterLocalNotificationsPlugin(),
      );
      await NotificationService.init();
      log.clear();

      await NotificationService.instance.syncToSlots(const []);

      expect(log.where((c) => c.method == 'show'), isEmpty);
      expect(log.where((c) => c.method == 'cancel'), hasLength(4));
    });

    test(
      'syncToSlots cancels a slot whose meal was logged after it fired',
      () async {
        final log = installFakeAndroidNotifications();
        NotificationService.resetForTesting(
          plugin: FlutterLocalNotificationsPlugin(),
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
