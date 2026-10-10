/// Wires "Fill all with catering" into the log form.
///
/// Its own file because `log_meal_screen.dart` and
/// `log_meal_kuchnia_mixin.dart` are both at the repo's 250-line ceiling. The
/// rule lives in `kuchnia_fill.dart` and the two-tap state in
/// `kuchnia_fill_flow.dart`; this only connects them to the screen.
library;

import 'package:diet_guard_app/screens/log_meal_kuchnia_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_sync_mixin.dart';
import 'package:diet_guard_app/services/kuchnia_fill_flow.dart';
import 'package:diet_guard_app/services/kuchnia_queue.dart';
import 'package:diet_guard_app/services/kuchnia_spread.dart';
import 'package:flutter/material.dart';

/// Drives the screen's [FillAllFlow] and tidies the screen after a fill.
mixin LogMealFillMixin<T extends StatefulWidget>
    on LogMealSyncMixin<T>, LogMealKuchniaMixin<T> {
  /// The flow behind the button. Per-screen, so leaving the screen drops an
  /// armed proposal along with it.
  FillAllFlow fillFlow = FillAllFlow();

  /// Shows [message] in the form's status line. Supplied by the screen.
  void showFillStatus(String message);

  /// Runs one tap: the first proposes, a second on the same day confirms.
  Future<void> onFillAll() async {
    final pending = fillFlow.tap();
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
      if (mounted) showFillStatus('Fill all failed: $error');
      return;
    }
    if (!mounted) return;
    setState(() {});
    if (outcome == null) return;
    if (outcome.written.isNotEmpty) await _afterFill(outcome.written);
    if (!mounted) return;
    showFillStatus(outcome.message);
  }

  /// Disarms a proposal without writing anything.
  void onFillCancel() {
    fillFlow.cancel();
    showFillStatus('Fill all cancelled — nothing logged.');
  }

  /// Publishes the batch once and drops the filled dishes from the delivery
  /// queue, so "Today's delivery (N more to go)" and the prefilled form do
  /// not keep offering meals that were just logged.
  Future<void> _afterFill(List<SlottedDish> written) async {
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
