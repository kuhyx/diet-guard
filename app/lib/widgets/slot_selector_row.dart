/// A single row that both shows today's slot status (logged/due/upcoming)
/// and lets the user pick which slot they're logging for, replacing what
/// used to be three separate stacked elements.
library;

import 'package:diet_guard_app/models/slot.dart';
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
    final elapsed = elapsedSlots(now).toSet();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        ...daySlots().map((slot) {
          final isLogged = loggedSlots.contains(slot);
          final isDue = !isLogged && elapsed.contains(slot);
          final color = isLogged
              ? Colors.green
              : isDue
              ? Colors.red
              : Colors.grey;
          final isSelected = selectedSlot == slot;
          return ChoiceChip(
            label: Text(slotLabel(slot)),
            selected: isSelected,
            avatar: isLogged ? Icon(Icons.check, size: 14, color: color) : null,
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
          avatar: const Icon(Icons.fastfood, size: 14),
          selected: selectedSlot == null,
          onSelected: (_) => onSlotSelected(null),
        ),
      ],
    );
  }
}
