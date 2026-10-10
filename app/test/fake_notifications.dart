import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// The channel id `LocalNotificationsBackend` posts reminders on -- and the
/// one older, hour-keyed builds used too.
const reminderChannelId = 'diet_guard_due_slot';

/// Mocks the raw `dexterous.com/flutter/local_notifications` MethodChannel
/// the way the package's own test suite does
/// (`android_flutter_local_notifications_test.dart`), so
/// [NotificationService] can be exercised end-to-end (init/show/cancel)
/// without a real Android plugin.
///
/// Stateful, like the real notification shade: `show` adds an id, `cancel`
/// removes it, and `getActiveNotifications` reports what is left. Without
/// that, the active-id lookup `syncToSlots` relies on would always see an
/// empty shade and every orphan test would pass vacuously. Seed [active]
/// (id -> channel id) to simulate reminders a previous run or an older build
/// left behind.
///
/// Returns the call log so a test can assert which slots were shown vs.
/// cancelled.
List<MethodCall> installFakeAndroidNotifications({
  Map<int, String>? active,
}) {
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final log = <MethodCall>[];
  final shade = active ?? <int, String>{};

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        final args = call.arguments;
        switch (call.method) {
          case 'initialize':
            return true;
          case 'requestNotificationsPermission':
            return true;
          case 'show':
            final map = args as Map;
            final details = map['platformSpecifics'] as Map?;
            shade[map['id'] as int] =
                details?['channelId'] as String? ?? reminderChannelId;
            return null;
          case 'cancel':
            shade.remove((args as Map)['id']);
            return null;
          case 'getActiveNotifications':
            return [
              for (final entry in shade.entries)
                {'id': entry.key, 'channelId': entry.value},
            ];
          default:
            return null;
        }
      });

  addTearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  return log;
}
