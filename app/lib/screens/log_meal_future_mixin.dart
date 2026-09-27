/// Lets the user pre-log a meal against a future date + slot instead of now.
///
/// Its own file because `log_meal_screen.dart` is at the repo's 250-line cap.
///
/// Scoped to dates strictly after today: the date picker's `firstDate` is
/// tomorrow. Today's own not-yet-due slots keep using the screen's existing
/// [SlotSelectorRow] (driven by the real `DateTime.now()`), so this mixin
/// never has to reproduce its "due" (red) coloring, which is meaningless for
/// a day that hasn't started.
library;

import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/slot_selector_row.dart';
import 'package:flutter/material.dart';

/// Adds a future-date meal-log picker to [LogMealScreen]'s state.
mixin LogMealFutureMixin<T extends StatefulWidget> on State<T> {
  DateTime? _futureDate;
  int? _futureSlot;
  Set<int> _futureLoggedSlots = {};

  /// The date currently chosen for a future log, or null when logging for
  /// today through the screen's normal flow.
  DateTime? get futureDate => _futureDate;

  /// The slot chosen for [futureDate], or null until one is picked.
  int? get futureSlot => _futureSlot;

  /// Clears back to "log for today", dropping the picked date and slot.
  void resetFutureLog() {
    setState(() {
      _futureDate = null;
      _futureSlot = null;
      _futureLoggedSlots = {};
    });
  }

  Future<void> _pickFutureDate() async {
    final today = DateTime.now();
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final picked = await showDatePicker(
      context: context,
      firstDate: tomorrow,
      lastDate: tomorrow.add(const Duration(days: 365)),
      initialDate: _futureDate ?? tomorrow,
    );
    if (picked == null || !mounted) return;
    final log = await LogStorageService.instance.readLog();
    if (!mounted) return;
    final logged = (log[localDateKey(picked)] ?? const [])
        .where((entry) => !entry.deleted && entry.slot != null)
        .map((entry) => entry.slot!)
        .toSet();
    setState(() {
      _futureDate = picked;
      _futureLoggedSlots = logged;
      _futureSlot = null;
    });
  }

  /// The "When" row: a "Log for later" button, or the picked date with a
  /// button to change it and one to clear back to today.
  Widget buildWhenRow(BuildContext context) {
    final date = _futureDate;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.event, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.xs),
        Expanded(child: Text(date == null ? 'Today' : localDateKey(date))),
        TextButton.icon(
          // Not Icons.calendar_month: the app bar's own "Calendar" nav button
          // already uses that, and a second one on screen makes
          // `find.byIcon` ambiguous for widget tests (and taps) alike.
          icon: const Icon(Icons.date_range, size: 18),
          label: Text(date == null ? 'Log for later' : 'Change date'),
          onPressed: _pickFutureDate,
        ),
        if (date != null)
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Back to today',
            onPressed: resetFutureLog,
          ),
      ],
    );
  }

  /// The slot row to show: [futureDate]'s own (driven by that date's logged
  /// slots) when a future date is picked, otherwise today's, built from the
  /// screen's own state and [onTodaySlotSelected].
  Widget buildSlotRow({
    required Set<int> loggedSlots,
    required int? selectedSlot,
    required ValueChanged<int?> onTodaySlotSelected,
  }) {
    final date = _futureDate;
    if (date == null) {
      return SlotSelectorRow(
        now: DateTime.now(),
        loggedSlots: loggedSlots,
        selectedSlot: selectedSlot,
        onSlotSelected: onTodaySlotSelected,
      );
    }
    return SlotSelectorRow(
      now: DateTime(date.year, date.month, date.day),
      loggedSlots: _futureLoggedSlots,
      selectedSlot: _futureSlot,
      onSlotSelected: (slot) => setState(() => _futureSlot = slot),
    );
  }

  /// Resolves the slot/time to log against: the future pick when one is
  /// active, otherwise [todaySlot] for now. `error` is set instead when a
  /// future date is chosen but no slot on it has been picked yet.
  ({String? error, int? slot, DateTime? when}) resolveLogTarget(
    int? todaySlot,
  ) {
    final date = _futureDate;
    if (date == null) return (error: null, slot: todaySlot, when: null);
    final slot = _futureSlot;
    if (slot == null) {
      return (
        error: 'Pick a slot for that date first.',
        slot: null,
        when: null,
      );
    }
    return (
      error: null,
      slot: slot,
      when: DateTime(date.year, date.month, date.day, slot),
    );
  }
}
