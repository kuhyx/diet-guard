/// Shows/cancels the per-slot "meal not logged" notification, mirroring
/// diet_guard's `_gate.py` lock decision -- but as a notification rather
/// than a screen-grab, and re-evaluated on every background check tick
/// rather than fired once.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Wraps [FlutterLocalNotificationsPlugin] so the due-slot notification
/// logic ([syncToSlots]) is unit-testable against a fake platform channel,
/// independent of the real plugin's native implementation.
class NotificationService {
  NotificationService._(this._plugin);

  static NotificationService? _instance;

  final FlutterLocalNotificationsPlugin _plugin;

  bool _initialized = false;

  static const _channelId = 'diet_guard_due_slot';
  static const _channelName = 'Meal reminders';

  /// Returns the initialized singleton; throws if [init] was not called.
  static NotificationService get instance => _instance!;

  /// Initializes the singleton with the real plugin (idempotent -- a
  /// second call returns the already-initialized instance without
  /// re-running platform setup).
  static Future<NotificationService> init() async {
    final svc = _instance ??= NotificationService._(
      FlutterLocalNotificationsPlugin(),
    );
    if (!svc._initialized) {
      // `linux:` is required whenever the app runs on Linux (the desktop
      // build used to visually verify screens); this app has no real
      // Linux target otherwise.
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      );
      await svc._plugin.initialize(settings: settings);
      svc._initialized = true;
    }
    return svc;
  }

  /// Resets the singleton so tests can inject a plugin pointed at a fake
  /// platform channel. A subsequent [init] call drives that fake's
  /// `initialize` codepath, same as production.
  @visibleForTesting
  static void resetForTesting({FlutterLocalNotificationsPlugin? plugin}) {
    _instance = plugin == null ? null : NotificationService._(plugin);
  }

  /// Requests Android 13+'s runtime `POST_NOTIFICATIONS` permission.
  ///
  /// Returns null on platforms where this Android-specific call doesn't
  /// apply -- the caller treats null and false the same way (don't block on
  /// it; notifications degrade silently if denied, matching the rest of
  /// this service's silent-on-failure stance). This app only ships an
  /// `android/` target, so in production the non-null path always runs;
  /// the fallback exists for the Linux desktop build used to visually
  /// verify this screen, where `resolvePlatformSpecificImplementation`
  /// correctly resolves to null -- not reachable from `flutter test`
  /// without polluting the process-global plugin registration other tests
  /// in this file rely on, so it's excluded from coverage rather than
  /// chased with a fragile test-ordering trick.
  Future<bool?> requestPermission() =>
      _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission() ??
      // coverage:ignore-line
      Future.value();

  /// Shows a notification for every slot in [dueSlots] and cancels one for
  /// every other known slot.
  ///
  /// Idempotent and re-evaluated every tick: a slot logged after its
  /// notification fired gets that notification cancelled on the very next
  /// call, mirroring `_gate.gate_is_due()`'s re-evaluate-every-tick
  /// behavior rather than firing once and forgetting.
  Future<void> syncToSlots(List<int> dueSlots) async {
    final due = dueSlots.toSet();
    for (final slot in daySlots()) {
      if (due.contains(slot)) {
        await _show(slot);
      } else {
        await _plugin.cancel(id: slot);
      }
    }
  }

  Future<void> _show(int slot) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _plugin.show(
      id: slot,
      title: 'Meal not logged',
      body: "You haven't logged your ${slotLabel(slot)} meal yet.",
      notificationDetails: details,
    );
  }
}
