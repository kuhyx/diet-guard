/// The platform notification surface behind [NotificationService].
library;

/// Shows and cancels one notification per meal slot.
///
/// Free of any plugin import so [NotificationService]'s due-slot logic
/// compiles for web: the implementations are
/// `notification_backend_io.dart` (`flutter_local_notifications`) and
/// `notification_backend_web.dart` (the browser's Notifications API),
/// selected by the conditional export in
/// `notification_backend_factory.dart`.
abstract class NotificationBackend {
  /// Prepares the platform surface. Called once, before any [show]/[cancel].
  Future<void> initialize();

  /// Asks the platform for permission to post notifications.
  ///
  /// Returns null where the concept does not apply, which callers treat the
  /// same as false: notifications degrade silently rather than blocking use
  /// of the app.
  Future<bool?> requestPermission();

  /// Posts (or replaces) the notification for [slot].
  Future<void> show(int slot, String title, String body);

  /// Removes the notification for [slot], if one is showing.
  Future<void> cancel(int slot);
}
