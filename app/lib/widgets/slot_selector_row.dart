/// A single row that both shows today's slot status (logged/due/upcoming)
/// and lets the user pick which slot they're logging for, replacing what
/// used to be three separate stacked elements.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// One row of [ChoiceChip]s: one per today's slot hour plus a fixed
/// "Snack" chip. Each hour chip is simultaneously selectable (tap to log
/// for that slot) and status-colored (green+check = logged, red = due,
/// grey = upcoming), so no separate status bar or caption text is needed.
class SlotSelectorRow extends StatelessWidget {
  /// Creates a [SlotSelectorRow].
  const SlotSelectorRow({
    required this.now,
    required this.loggedSlots,
    required this.selectedSlot,
    required this.onSlotSelected,
    super.key,
  });

  /// Reference time used to decide which slots are due.
  final DateTime now;

  /// Slot hours already satisfied by today's log.
  final Set<int> loggedSlots;

  /// The slot currently chosen to log for, or null for "Snack".
  final int? selectedSlot;

  /// Called with the tapped slot's hour, or null for the "Snack" chip.
  final ValueChanged<int?> onSlotSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A `!` here would crash in any context that doesn't build its theme
    // from buildAppTheme() -- most widget tests just wrap in a bare
    // MaterialApp(home: ...). Falling back to the app's own dark instance
    // matches production exactly when the extension is genuinely absent.
    final statusColors =
        Theme.of(context).extension<AppStatusColors>() ?? AppStatusColors.dark;
    final elapsed = elapsedSlots(now).toSet();
    // Snack has no logged/due/upcoming status like the hour chips, so it
    // uses `accent` as its "color" instead of a status color -- but still
    // needs every property below set explicitly like the hour chips are.
    // Leaving any of them unset falls through to Flutter's own ChoiceChip
    // default, a literal pure-white border (the one banned value in this
    // system) -- the open finding the unified-design-system doc flagged.
    final snackSelected = selectedSlot == null;
    final snackColor = snackSelected ? scheme.primary : scheme.onSurfaceVariant;
    return Wrap(
      spacing: AppSpacing.xs + 2,
      runSpacing: AppSpacing.xs,
      children: [
        ...daySlots().map((slot) {
          final isLogged = loggedSlots.contains(slot);
          final isDue = !isLogged && elapsed.contains(slot);
          final color = isLogged
              ? statusColors.success
              : isDue
              ? scheme.error
              : scheme.onSurfaceVariant;
          final isSelected = selectedSlot == slot;
          return ChoiceChip(
            label: Text(slotLabel(slot)),
            selected: isSelected,
            // Icon reads lighter than the label text (rule 28): reduced
            // opacity instead of the label's full-strength color.
            avatar: isLogged
                ? Icon(
                    Icons.check,
                    size: 14,
                    color: color.withValues(alpha: 0.72),
                  )
                : null,
            backgroundColor: color.withValues(alpha: 0.15),
            selectedColor: color.withValues(alpha: 0.35),
            labelStyle: TextStyle(color: color),
            side: BorderSide(
              width: isSelected ? 2 : 1,
              color: isSelected ? color : color.withValues(alpha: 0.4),
            ),
            onSelected: (_) => onSlotSelected(slot),
          );
        }),
        ChoiceChip(
          label: const Text('Snack'),
          // Icon reads lighter than the label text (rule 28): reduced
          // opacity instead of the label's full-strength color.
          avatar: Icon(
            Icons.fastfood,
            size: 14,
            color: snackColor.withValues(alpha: 0.72),
          ),
          selected: snackSelected,
          backgroundColor: scheme.onSurfaceVariant.withValues(alpha: 0.15),
          selectedColor: scheme.primary.withValues(alpha: 0.35),
          labelStyle: TextStyle(color: snackColor),
          side: BorderSide(
            width: snackSelected ? 2 : 1,
            color: snackSelected
                ? snackColor
                : snackColor.withValues(alpha: 0.4),
          ),
          onSelected: (_) => onSlotSelected(null),
        ),
      ],
    );
  }
}
