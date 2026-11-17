/// Due mode: some slot has elapsed with nothing logged.
///
/// The log screen then strips everything that is not "log this meal now" (the
/// app bar, sync banner, date row), hides the Android status bar, and targets
/// the oldest due slot with both the check and the sparkle. Its own file
/// because `log_meal_screen.dart` is at the repo's 250-line ceiling.
///
/// Slot arithmetic is not touched here: due slots come from `missingSlots`
/// and the nearest-slot rule from `slotForLog`, both in `models/slot.dart`.
library;

import 'dart:async';

import 'package:diet_guard_app/models/slot.dart';
import 'package:diet_guard_app/screens/log_meal_sync_mixin.dart';
import 'package:diet_guard_app/services/meal_schedule_service.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// The clock the log screen reads for "which slots are due".
///
/// A hook rather than a constructor argument so the whole screen suite can pin
/// it once (`flutter_test_config.dart` pins 07:00, before the first slot);
/// otherwise every nav and slot test would pass at night and fail by day, once
/// due mode hides the app bar.
@visibleForTesting
DateTime Function() logMealClock = DateTime.now;

/// Shows or hides the Android status bar.
///
/// `main.dart` sets no system-UI mode, so "visible" is the platform default:
/// both bars shown. [hidden] true is sticky-immersive; false puts both back.
@visibleForTesting
Future<void> Function({required bool hidden}) setStatusBarHidden = _setBars;

Future<void> _setBars({required bool hidden}) => hidden
    ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
    : SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );

/// Due-mode state and slot targeting for the log screen's state.
mixin LogMealDueMixin<T extends StatefulWidget> on LogMealSyncMixin<T> {
  /// Whether the first read of today's log has finished. Until then the
  /// screen draws neither mode, so it never flashes the app bar and drops it.
  bool slotsLoaded = false;

  bool _statusBarHidden = false;

  /// What the screen reads as "now" (see [logMealClock]).
  DateTime get screenNow => logMealClock();

  /// Elapsed slots with nothing logged, oldest first.
  List<int> get dueSlots =>
      missingSlots(screenNow, loggedSlots, MealScheduleService.current);

  /// Whether the screen is in due mode.
  bool get dueMode => slotsLoaded && dueSlots.isNotEmpty;

  /// The slot a log or a send lands in: the oldest due slot, else the slot
  /// nearest [screenNow] (`slotForLog`).
  int get targetSlot => dueSlots.isNotEmpty
      ? dueSlots.first
      : slotForLog(screenNow, MealScheduleService.current);

  @override
  Future<void> refreshSlots() async {
    await super.refreshSlots();
    if (!mounted) return;
    setState(() => slotsLoaded = true);
    await syncStatusBar();
  }

  /// Hides the status bar while in due mode and restores it on exit.
  Future<void> syncStatusBar() async {
    final hide = dueMode;
    if (hide == _statusBarHidden) return;
    _statusBarHidden = hide;
    await setStatusBarHidden(hidden: hide);
  }

  /// Puts the status bar back; call from `dispose`.
  void restoreStatusBar() {
    if (!_statusBarHidden) return;
    _statusBarHidden = false;
    unawaited(setStatusBarHidden(hidden: false));
  }
}
