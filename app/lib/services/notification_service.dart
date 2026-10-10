/// Shows/cancels the per-slot "meal not logged" notification, mirroring
/// diet_guard's `_gate.py` lock decision -- but as a notification rather
/// than a screen-grab, and re-evaluated on every background check tick
/// rather than fired once.
library;

import 'package:diet_guard_app/models/meal_schedule.dart';
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

  /// Shows a notification for every slot minute in [dueSlots] and cancels
  /// every other reminder this app has showing.
  ///
  /// Idempotent and re-evaluated every tick: a slot logged after its
  /// notification fired gets that notification cancelled on the very next
  /// call, mirroring `_gate.gate_is_due()`'s re-evaluate-every-tick
  /// behavior rather than firing once and forgetting.
  ///
  /// The slot minute doubles as the notification id, so a schedule change
  /// leaves ids no current slot names -- and so does the upgrade itself,
  /// because older builds used the slot *hour* (0..23) as the id. Iterating
  /// only today's slots would leave those posted forever, nagging about
  /// checkpoints that no longer exist. Rather than sweeping all 1440 possible
  /// ids (a platform call each, every ~15 min from a background isolate),
  /// this asks the platform which reminders are actually showing and cancels
  /// those not due: one lookup plus one call per real notification, and
  /// complete by construction, since an orphan is by definition something
  /// showing. Only when that lookup fails does it fall back to the full
  /// sweep, paying the cost on that one tick to keep the guarantee.
  Future<void> syncToSlots(List<int> dueSlots) async {
    final due = dueSlots.toSet();
    Iterable<int> stale;
    try {
      stale = (await _backend.activeIds()).difference(due);
    } on Object {
      stale = [
        for (var id = 0; id < kMinutesPerDay; id++)
          if (!due.contains(id)) id,
      ];
    }
    for (final id in stale) {
      await _backend.cancel(id);
    }
    for (final slot in due) {
      await _backend.show(
        slot,
        'Meal not logged',
        "You haven't logged your ${slotLabel(slot)} meal yet.",
      );
    }
  }
}
