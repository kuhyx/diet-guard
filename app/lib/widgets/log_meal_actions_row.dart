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
        // Expanded so the delivery button takes the slack and pushes the log
        // button right; the queue is a numeral next to the icon, so there is
        // no wide label to clip. While fetching the icon becomes a spinner.
        if (canFetch)
          Expanded(
            child: OutlinedButton(
              onPressed: deliveryBusy ? null : onLoadDelivery,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (deliveryBusy)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(
                      Icons.restaurant,
                      semanticLabel: "Load today's catering delivery",
                    ),
                  if (dishesQueued > 0) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Text('$dishesQueued'),
                  ],
                ],
              ),
            ),
          ),
        // No Spacer when the delivery button is present: it is a flex child
        // too and would split the free space with the Expanded above.
        if (!canFetch) const Spacer(),
        const SizedBox(width: AppSpacing.sm),
        FilledButton(
          onPressed: onLog,
          child: const Icon(Icons.check_circle, semanticLabel: 'Log meal'),
        ),
      ],
    );
  }
}
