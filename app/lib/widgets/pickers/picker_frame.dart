/// The shared dialog around every picker: a centred, width-capped [Dialog]
/// with a close icon (cancel) and a check icon (confirm), no words.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Picker chrome. Outside tap and Esc cancel (the dialog route's own
/// dismiss); Enter confirms when [canConfirm].
///
/// The icons carry spoken-only `semanticLabel`s and no `tooltip:`, which
/// would paint the word on long-press.
class PickerFrame extends StatelessWidget {
  /// Creates a [PickerFrame].
  const PickerFrame({
    required this.child,
    required this.canConfirm,
    required this.onConfirm,
    super.key,
  });

  /// The picker body.
  final Widget child;

  /// Whether the check is enabled (a half-chosen range is not).
  final bool canConfirm;

  /// Pops the dialog with the chosen value.
  final VoidCallback onConfirm;

  void _enter() {
    if (canConfirm) onConfirm();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(AppSpacing.md),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppWidth.picker),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Around the body only: Enter on a focused close icon must
            // reach that button (cancel), not bubble up into a confirm.
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _enter,
                const SingleActivator(LogicalKeyboardKey.numpadEnter): _enter,
              },
              child: child,
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: AppSpacing.sm,
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, semanticLabel: 'Cancel'),
                ),
                IconButton.filled(
                  onPressed: canConfirm ? onConfirm : null,
                  icon: const Icon(Icons.check, semanticLabel: 'Confirm'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
