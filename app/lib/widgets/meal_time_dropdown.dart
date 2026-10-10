/// A minute-of-day picker: a 15-minute dropdown plus an exact-time button.
library;

import 'dart:async';

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Picks a minute of day, offering the 15-minute grid within
/// [minMinute]..[maxMinute], with a clock button beside it that opens a time
/// picker for any minute in that range.
///
/// A separate button rather than a "Custom…" menu item: the menu opens
/// centred on the current value, so an item at either end of ~95 entries was
/// always a long scroll away.
///
/// The grid is what most people want and keeps the list short; the button
/// exists because an endpoint may legitimately sit off the grid (07:23 to
/// match a train), and because the PC can set such a value and sync it here.
/// That second case is why the current [value] is always offered as an item
/// even when it is off-grid or outside the range: a [DropdownButton] whose
/// value matches no item asserts, which would take the settings screen down
/// over a value another device wrote.
class MealTimeDropdown extends StatelessWidget {
  /// Creates a [MealTimeDropdown].
  const MealTimeDropdown({
    required this.label,
    required this.value,
    required this.minMinute,
    required this.maxMinute,
    required this.onChanged,
    this.gridMaxMinute,
    super.key,
  });

  /// The field label, e.g. "First meal".
  final String label;

  /// The current minute of day.
  final int value;

  /// Earliest minute offered (inclusive).
  final int minMinute;

  /// Latest minute offered (inclusive), via the clock button if not the grid.
  final int maxMinute;

  /// Latest grid mark listed, when it must stop short of [maxMinute] (the
  /// first meal's grid ends at 23:30 so a grid-aligned last meal still fits,
  /// while the clock button may go to 23:44). Defaults to [maxMinute].
  final int? gridMaxMinute;

  /// Called with the chosen minute, already clamped into
  /// [minMinute]..[maxMinute]. Not called when the picker is dismissed.
  final ValueChanged<int> onChanged;

  /// The minutes listed, ascending: the grid marks in range plus [value].
  List<int> get options {
    final first =
        (minMinute + kSlotGridMinutes - 1) ~/
        kSlotGridMinutes *
        kSlotGridMinutes;
    return {
      for (
        var m = first;
        m <= (gridMaxMinute ?? maxMinute);
        m += kSlotGridMinutes
      )
        m,
      value,
    }.toList()..sort();
  }

  int _clampToRange(int minute) => minute < minMinute
      ? minMinute
      : (minute > maxMinute ? maxMinute : minute);

  Future<void> _pickExact(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: value ~/ 60, minute: value % 60),
      helpText: label,
      // The rest of the app writes times as HH:MM; an AM/PM dial here would
      // be the one place that reads differently.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return;
    // Clamped rather than rejected: the picker cannot be told the range, and
    // the nearest legal minute is what `MealSchedule.normalized` would
    // produce anyway -- doing it here keeps the dropdown's own contract.
    onChanged(_clampToRange(picked.hour * 60 + picked.minute));
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: AppWidth.field),
    child: Row(
      spacing: AppSpacing.xs,
      children: [
        Expanded(
          child: InputDecorator(
            decoration: InputDecoration(labelText: label),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: value,
                isDense: true,
                isExpanded: true,
                items: [
                  for (final minute in options)
                    DropdownMenuItem(
                      value: minute,
                      child: Text(slotLabel(minute)),
                    ),
                ],
                onChanged: (minute) =>
                    minute == null ? null : onChanged(minute),
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.schedule),
          tooltip: 'Type or pick an exact time',
          onPressed: () => unawaited(_pickExact(context)),
        ),
      ],
    ),
  );
}
