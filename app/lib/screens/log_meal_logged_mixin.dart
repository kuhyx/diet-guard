/// The meals the screen logged for the user, shown below the action row with
/// an undo, plus the catering auto-log that fills the first of them.
///
/// The rows stay until the next meal is logged. Undo tombstones that one entry
/// by id (`deleteEntry`, never `undoLastToday`: several rows can be on screen,
/// and an auto-logged dish is not necessarily the newest entry), so the
/// deterministic catering id keeps blocking a re-log on the next open.
library;

import 'dart:async';

import 'package:diet_guard_app/screens/log_meal_due_mixin.dart';
import 'package:diet_guard_app/screens/log_meal_sync_mixin.dart';
import 'package:diet_guard_app/services/kuchnia_autolog.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/logged_meal_row.dart';
import 'package:material_ui/material_ui.dart';

/// Logged-meal rows, undo and the catering auto-log.
mixin LogMealLoggedMixin<T extends StatefulWidget>
    on LogMealSyncMixin<T>, LogMealDueMixin<T> {
  /// The rows under the action row, oldest first.
  List<LoggedMeal> loggedRows = const [];

  /// Replaces the rows with [meals]: a new log retires the previous ones.
  void showLogged(List<LoggedMeal> meals) {
    if (mounted) setState(() => loggedRows = meals);
  }

  /// Tombstones [meal]'s entry, drops its row and republishes.
  Future<void> undoLogged(LoggedMeal meal) async {
    final id = meal.entry.id;
    if (id == null) return;
    setState(() => loggedRows = [...loggedRows]..remove(meal));
    await LogStorageService.instance.deleteEntry(id);
    await publishAfterLog();
    await refreshSlots();
  }

  /// Logs the delivered dishes of the due slots, no tap needed.
  ///
  /// The old rule "a delivered meal is not an eaten meal" was overridden by
  /// kuhy on 2026-11-17 ("LOG EVEN WITHOUT TAP"). Safe to call repeatedly: the
  /// ids are deterministic (see `kuchnia_autolog.dart`).
  Future<void> autoLogCatering() async {
    if (!dueMode) return;
    final entries = await KuchniaAutoLog.instance.logDue(dueSlots);
    if (!mounted || entries.isEmpty) return;
    showLogged([for (final e in entries) LoggedMeal(e, LoggedOrigin.catering)]);
    await publishAfterLog();
    await refreshSlots();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A resume does what an open does, with one sync (autoSync is
    // single-flight, so calling super too would let the auto-log run before
    // the pull finished). Pause still pushes through the sync mixin.
    if (state == AppLifecycleState.resumed) {
      unawaited(onOpenedOrResumed());
      return;
    }
    super.didChangeAppLifecycleState(state);
  }

  /// What a fresh open or a resume does: show the screen from the local log,
  /// pull what other devices logged, then auto-log what is still due.
  Future<void> onOpenedOrResumed() async {
    unawaited(refreshSlots());
    await autoSync();
    await refreshSlots();
    await autoLogCatering();
  }
}
