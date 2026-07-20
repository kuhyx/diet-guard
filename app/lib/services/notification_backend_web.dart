/// Browser-Notifications-API [NotificationBackend] for the desktop app.
///
/// A browser notification only exists while the page that raised it is open,
/// so this is a genuinely weaker surface than Android's: closing the desktop
/// window drops every pending reminder. That is accepted -- the PC's real
/// backstop is `diet-guard-gate.timer`, which locks the screen rather than
/// asking politely.
library;

import 'dart:js_interop';

import 'package:diet_guard_app/services/notification_backend.dart';
import 'package:web/web.dart' as web;

/// [NotificationBackend] over the browser's `Notification` API.
class WebNotificationBackend implements NotificationBackend {
  /// Live notifications by slot, so [cancel] can close the right one. The
  /// `tag` also makes the browser replace rather than stack a re-shown slot;
  /// the map is what makes an explicit close possible.
  final _shown = <int, web.Notification>{};

  bool _granted = false;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool?> requestPermission() async {
    if (web.Notification.permission == 'granted') {
      _granted = true;
      return true;
    }
    if (web.Notification.permission == 'denied') return false;
    final result = await web.Notification.requestPermission().toDart;
    return _granted = result.toDart == 'granted';
  }

  @override
  Future<void> show(int slot, String title, String body) async {
    // Posting without permission throws; a silent no-op matches this
    // service's degrade-quietly stance everywhere else.
    if (!_granted) return;
    _shown[slot] = web.Notification(
      title,
      web.NotificationOptions(body: body, tag: 'diet_guard_slot_$slot'),
    );
  }

  @override
  Future<void> cancel(int slot) async {
    _shown.remove(slot)?.close();
  }
}

/// Opens the platform notification backend.
NotificationBackend openNotificationBackend() => WebNotificationBackend();
