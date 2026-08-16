/// A single row that both shows today's slot status (logged/due/upcoming)
/// and lets the user pick which slot they're logging for, replacing what
/// used to be three separate stacked elements.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// One row of [ChoiceChip]s, one per today's slot hour. Each chip is
/// simultaneously selectable (tap to log for that slot) and status-colored
/// (green+check = logged, red = due, grey = upcoming), so no separate status
/// bar or caption text is needed.
///
/// There used to be a fifth "Snack" chip that selected no slot at all,
/// removed 2026-08-14. Entries with a null slot still exist in storage and
/// still arrive over sync, so the nullable types below are deliberate -- but
/// this widget no longer produces one.
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

  /// The slot currently chosen to log for. Nullable for historical reasons
  /// (see the class doc); no chip in this row selects null any more.
  final int? selectedSlot;

  /// Called with the tapped slot's hour. Never called with null.
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
    final schedule = MealScheduleService.current;
    final elapsed = elapsedSlots(now, schedule).toSet();
    // One row, always. A Wrap dropped the later pills onto a second line as
    // soon as the row outgrew the width, which it does even at four: a logged
    // chip measures ~124px at Material defaults, so four already need 522px
    // against ~330px of phone width.
    //
    // FittedBox scales the whole row down uniformly instead. A Row of
    // Expanded children also avoids the wrap, but imposes a *tight* width on
    // each chip, and a Chip narrower than avatar+padding+label clips its label
    // rather than shrinking -- measured at 10px per label, about one
    // character, and it throws no overflow error while doing it.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.xs + 2,
        children: [
          ...daySlots(schedule).map((slot) {
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
              // Trim the Material defaults so the row needs less scaling down:
              // every pixel saved here is legibility kept at six meals.
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onSelected: (_) => onSlotSelected(slot),
            );
          }),
        ],
      ),
    );
  }
}
