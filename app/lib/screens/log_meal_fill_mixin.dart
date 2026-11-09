/// Wires "Fill all with catering" into the log form.
///
/// Its own file because `log_meal_screen.dart` and
/// `log_meal_kuchnia_mixin.dart` are both at the repo's 250-line ceiling. The
/// rule lives in `kuchnia_fill.dart` and the two-tap state in
/// `kuchnia_fill_flow.dart`; this only connects them to the screen.
library;

import 'package:diet_guard_app/screens/log_meal_future_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_kuchnia_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_sync_mixin.dart';
import 'package:diet_guard_app/services/kuchnia_fill_flow.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:flutter/material.dart';

/// One fill tap's status (see [CountCue]).
typedef FillCue = CountCue;

/// The cue for a tap's [outcome]: dishes logged (ok + N), a proposal of
/// [armed] dishes (info + N), or nothing done (warn + 0: no delivery, every
/// slot taken, or the fetch failed).
FillCue fillCue(FillOutcome outcome, {required int armed}) {
  final written = outcome.written.length;
  final label = outcome.message;
  if (written > 0) return (label: label, kind: CueKind.ok, count: written);
  if (armed > 0) return (label: label, kind: CueKind.info, count: armed);
  return (label: label, kind: CueKind.warn, count: 0);
}

/// Drives the screen's [FillAllFlow] and tidies the screen after a fill.
mixin LogMealFillMixin<T extends StatefulWidget>
    on LogMealSyncMixin<T>, LogMealKuchniaMixin<T>, LogMealFutureMixin<T> {
  /// The flow behind the button. Per-screen, so leaving the screen drops an
  /// armed proposal along with it.
  FillAllFlow fillFlow = FillAllFlow();

  /// Shows [cue] as a status cue (its label is only spoken). Supplied by the
  /// screen.
  void showFillStatus(FillCue cue);

  /// A proposal belongs to the date it was fetched for; picking another (or
  /// going back to today) must not leave "Confirm (N)" offering it.
  @override
  void onLogDateChanged() {
    super.onLogDateChanged();
    fillFlow.cancel();
  }

  /// Runs one tap: the first proposes, a second on the same day confirms.
  /// Fills the "Log for later" date when one is picked, else today.
  Future<void> onFillAll() async {
    final day = futureDate;
    final pending = fillFlow.tap(day: day);
    setState(() {}); // show the busy label while the fetch/writes run
    final FillOutcome? outcome;
    try {
      outcome = await pending;
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {});
      // A confirm can fail partway through its writes. Whatever did land is
      // a real meal, so it is published like any other rather than waiting
      // for the next tick, and the user is told the batch did not finish.
      await publishAfterLog();
      await refreshSlots();
      if (mounted) {
        showFillStatus((
          label: 'Fill all failed: $error',
          kind: CueKind.error,
          count: null,
        ));
      }
      return;
    }
    if (!mounted) return;
    setState(() {});
    if (outcome == null) return;
    if (outcome.written.isNotEmpty) {
      await _afterFill(outcome.written, later: day != null);
    }
    if (!mounted) return;
    showFillStatus(fillCue(outcome, armed: fillFlow.armedCount));
  }

  /// Disarms a proposal without writing anything.
  void onFillCancel() {
    fillFlow.cancel();
    showFillStatus((
      label: 'Fill all cancelled — nothing logged.',
      kind: CueKind.info,
      count: null,
    ));
  }

  /// Publishes the batch once and drops the filled dishes from the delivery
  /// queue, so "Today's delivery (N more to go)" and the prefilled form do
  /// not keep offering meals that were just logged.
  ///
  /// A [later] fill logged another day's delivery: today's queue and form are
  /// left alone, and the screen goes back to today, as after a manual
  /// "Log for later" -- the picked day's slot row would otherwise be stale.
  Future<void> _afterFill(
    List<SlottedDish> written, {
    required bool later,
  }) async {
    if (later) {
      resetFutureLog();
      await publishAfterLog();
      await refreshSlots();
      return;
    }
    if (KuchniaQueueService.isInitialized) {
      for (final item in written) {
        KuchniaQueueService.instance.markLogged(item.dish);
      }
    }
    final offered = offeredDish;
    if (offered != null &&
        written.any((item) => item.dish.bankKey == offered.bankKey)) {
      // The prefilled dish was just logged by the fill; leaving it in the
      // form would invite a second, duplicate submit.
      descController.clear();
      macroControllers.clear();
    }
    prefillNextDish();
    await publishAfterLog();
    await refreshSlots();
  }
}
