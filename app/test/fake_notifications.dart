import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mocks the raw `dexterous.com/flutter/local_notifications` MethodChannel
/// the way the package's own test suite does
/// (`android_flutter_local_notifications_test.dart`), so
/// [NotificationService] can be exercised end-to-end (init/show/cancel)
/// without a real Android plugin.
///
/// Returns the call log so a test can assert which slots were shown vs.
/// cancelled.
List<MethodCall> installFakeAndroidNotifications() {
  AndroidFlutterLocalNotificationsPlugin.registerWith();
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final log = <MethodCall>[];

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        log.add(call);
        switch (call.method) {
          case 'initialize':
            return true;
          case 'requestNotificationsPermission':
            return true;
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
