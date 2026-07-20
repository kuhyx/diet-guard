/// Shows/cancels the per-slot "meal not logged" notification, mirroring
/// diet_guard's `_gate.py` lock decision -- but as a notification rather
/// than a screen-grab, and re-evaluated on every background check tick
/// rather than fired once.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/notification_backend.dart';
import 'package:diet_guard_app/services/notification_backend_factory.dart';
import 'package:flutter/foundation.dart';

/// Owns the due-slot notification logic ([syncToSlots]) independently of the
/// platform surface that actually posts them: `flutter_local_notifications`
/// on Android, the browser's Notifications API in the desktop web build (see
/// `notification_backend.dart`).
class NotificationService {
  NotificationService._(this._backend);

  static NotificationService? _instance;

  final NotificationBackend _backend;

  bool _initialized = false;

  /// Returns the initialized singleton; throws if [init] was not called.
  static NotificationService get instance => _instance!;

  /// Initializes the singleton with the platform backend (idempotent -- a
  /// second call returns the already-initialized instance without
  /// re-running platform setup).
  static Future<NotificationService> init() async {
    final svc = _instance ??= NotificationService._(openNotificationBackend());
    if (!svc._initialized) {
      await svc._backend.initialize();
      svc._initialized = true;
    }
    return svc;
  }

  /// Resets the singleton so tests can inject a backend -- typically one over
  /// a plugin pointed at a fake platform channel. A subsequent [init] call
  /// drives that backend's `initialize` codepath, same as production.
  @visibleForTesting
  static void resetForTesting({NotificationBackend? backend}) {
    _instance = backend == null ? null : NotificationService._(backend);
  }

  /// Requests the platform's notification permission.
  ///
  /// Returns null where the concept doesn't apply; callers treat null and
  /// false the same way.
  Future<bool?> requestPermission() => _backend.requestPermission();

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
        await _backend.show(
          slot,
          'Meal not logged',
          "You haven't logged your ${slotLabel(slot)} meal yet.",
        );
      } else {
        await _backend.cancel(slot);
      }
    }
  }
}
