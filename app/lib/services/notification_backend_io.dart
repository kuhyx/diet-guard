/// `flutter_local_notifications`-backed [NotificationBackend] (Android).
library;

import 'package:diet_guard_app/services/notification_backend.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Wraps [FlutterLocalNotificationsPlugin] so the due-slot logic in
/// `notification_service.dart` is unit-testable against a fake platform
/// channel, independent of the real plugin's native implementation.
class LocalNotificationsBackend implements NotificationBackend {
  /// Creates a backend over [plugin].
  LocalNotificationsBackend(this.plugin);

  /// The wrapped plugin. Injectable so a test can point it at a fake channel.
  final FlutterLocalNotificationsPlugin plugin;

  static const _channelId = 'diet_guard_due_slot';
  static const _channelName = 'Meal reminders';

  @override
  Future<void> initialize() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await plugin.initialize(settings: settings);
  }

  /// Requests Android 13+'s runtime `POST_NOTIFICATIONS` permission.
  ///
  /// Returns null on platforms where this Android-specific call doesn't
  /// apply -- the caller treats null and false the same way (don't block on
  /// it; notifications degrade silently if denied, matching the rest of this
  /// service's silent-on-failure stance). Since the desktop target became a
  /// web build, `android/` is this backend's only real platform, so in
  /// production the non-null path always runs; the fallback is not reachable
  /// from `flutter test` without polluting the process-global plugin
  /// registration other tests in this file rely on, so it's excluded from
  /// coverage rather than chased with a fragile test-ordering trick.
  @override
  Future<bool?> requestPermission() =>
      plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission() ??
      // coverage:ignore-line
      Future.value();

  @override
  Future<void> show(int slot, String title, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await plugin.show(
      id: slot,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  @override
  Future<void> cancel(int slot) => plugin.cancel(id: slot);
}

/// Opens the platform notification backend.
NotificationBackend openNotificationBackend() =>
    LocalNotificationsBackend(FlutterLocalNotificationsPlugin());
