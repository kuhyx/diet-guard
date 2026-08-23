/// The log form's action row: load today's delivery, then log the meal.
///
/// Its own file because `log_meal_screen.dart` sits at the repo's 250-line
/// ceiling; lifting the whole row rather than just the delivery button keeps
/// both controls' layout in one place and returns budget to the screen.
library;

import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// A delivery button beside the log button.
///
/// The delivery control mirrors the PC lock screen's "🍱 Today's delivery":
/// standing in the kitchen, there must be something to tap. It stays visible
/// and enabled even when there is nothing to load — the outcome arrives as a
/// message rather than as a disabled button, because a disabled control gives
/// no way to retry after a late delivery and a hidden one reads as broken.
class LogMealActionsRow extends StatelessWidget {
  /// Creates the action row.
  const LogMealActionsRow({
    required this.onLoadDelivery,
    required this.onLog,
    this.deliveryBusy = false,
    this.dishesQueued = 0,
    this.canFetchDelivery,
    super.key,
  });

  /// Loads today's delivery and prefills the first/next dish.
  final Future<void> Function() onLoadDelivery;

  /// Writes the current form as a log entry.
  final VoidCallback onLog;

  /// Whether a delivery fetch is in flight; disables the button meanwhile so
  /// a second tap cannot start a concurrent login against the caterer.
  final bool deliveryBusy;

  /// How many delivered dishes are still queued, shown as the PC's
  /// "(N more to go)" so the user knows the walk is not finished.
  final int dishesQueued;

  /// Whether the platform can fetch at all. Defaults to
  /// [kuchniaFetchSupported] — false on web, where the desktop build runs and
  /// the caterer's panel blocks browser requests, so the control is hidden
  /// rather than shipped dead.
  final bool? canFetchDelivery;

  @override
  Widget build(BuildContext context) {
    final canFetch = canFetchDelivery ?? kuchniaFetchSupported;
    return Row(
      children: [
        // Flexible, not Spacer-and-hope: `OutlinedButton.icon` lays its label
        // out unbounded, so on a narrow phone the queue suffix renders wider
        // than the row and is clipped without ever throwing an overflow. The
        // Flexible caps the width and the FittedBox scales the text into it.
        if (canFetch)
          Expanded(
            child: Tooltip(
              message: "Load today's catering delivery",
              child: OutlinedButton.icon(
                onPressed: deliveryBusy ? null : onLoadDelivery,
                icon: const Icon(Icons.restaurant),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(_label, maxLines: 1),
                ),
              ),
            ),
          ),
        // No Spacer: it is a flex child too, so it would split the free space
        // with the Flexible above and re-create the clipping this guards
        // against. The Flexible takes the slack and pushes the log button
        // right on its own.
        if (!canFetch) const Spacer(),
        const SizedBox(width: AppSpacing.sm),
        Tooltip(
          message: 'Log meal',
          child: FilledButton(
            onPressed: onLog,
            child: const Icon(Icons.check_circle),
          ),
        ),
      ],
    );
  }

  String get _label {
    if (deliveryBusy) return 'Loading…';
    if (dishesQueued > 0) return "Today's delivery ($dishesQueued more to go)";
    return "Today's delivery";
  }
}
