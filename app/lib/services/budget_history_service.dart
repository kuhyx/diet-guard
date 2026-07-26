/// Persistence for the effective-from budget history.
///
/// Shaped exactly like [AppSettingsService]: a singleton over the platform
/// [DocumentStore], with a static getter that degrades to
/// [BudgetSchedule.empty] when uninitialised so widget tests that never call
/// [init] still render.
///
/// Mirrors the storage half of `diet_guard/_budget_history.py`. Kept in its
/// own document rather than folded into `app_settings.json` so the two have
/// independent write paths and the settings schema is untouched.
library;

import 'dart:convert';

import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/budget_schedule.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/document_store_factory.dart';
import 'package:flutter/foundation.dart';

/// Singleton owning the budget history document.
class BudgetHistoryService {
  BudgetHistoryService._(this._store);

  /// Document name this service owns.
  static const documentName = 'budget_history.json';

  static BudgetHistoryService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static BudgetHistoryService get instance => _instance!;

  /// True when [init]/[initForTesting]/[resetForTesting] has run.
  static bool get isInitialized => _instance != null;

  /// Returns the stored schedule, or an empty one when uninitialised.
  ///
  /// The fallback tracks the *current* goal rather than a fixed constant, so
  /// a device whose history is empty classifies days the same way the PC does
  /// (`_budget.current_schedule(default=daily_budget())`). A hardcoded 2200
  /// here would make the two devices disagree about the same log.
  static BudgetSchedule get schedule => BudgetSchedule(
    _instance?._schedule.entries ?? const [],
    fallback: AppSettingsService.dailyKcalGoal,
  );

  final DocumentStore _store;
  BudgetSchedule _schedule = BudgetSchedule.empty;

  /// Initialises the singleton against the platform document store.
  static Future<BudgetHistoryService> init() async {
    if (_instance != null) return _instance!;
    // Resolving the platform store is a plugin call (path_provider /
    // IndexedDB), not reachable from `flutter test`.
    // coverage:ignore-start
    final svc = BudgetHistoryService._(await openDocumentStore());
    // coverage:ignore-end
    await svc._load();
    _instance = svc;
    return svc;
  }

  /// Resets the singleton so [init] can be called again in tests.
  @visibleForTesting
  static void resetForTesting({DocumentStore? store}) {
    _instance = store == null ? null : BudgetHistoryService._(store);
  }

  /// Initialises from [store], calling the loader, for use in unit tests.
  @visibleForTesting
  static Future<BudgetHistoryService> initForTesting(
    DocumentStore store,
  ) async {
    final svc = BudgetHistoryService._(store);
    await svc._load();
    _instance = svc;
    return svc;
  }

  Future<void> _load() async {
    final raw = await _store.read(documentName);
    if (raw == null) return;
    try {
      _schedule = BudgetSchedule(BudgetSchedule.parse(jsonDecode(raw)));
    } on Exception {
      // Ignore parse errors: no history means "fall back to the current
      // scalar budget", which is exactly the pre-history behaviour.
    }
  }

  /// Grandfathers [kcal] to the beginning of time, if no history exists yet.
  ///
  /// Does nothing when [editedAt] is null: that means this device has never
  /// explicitly set a budget, so there is nothing of its own to grandfather
  /// and the [kDefaultDailyKcalGoal] fallback correctly covers every day.
  /// Also never overwrites a history already pulled from another device.
  Future<void> seedIfEmpty(int kcal, DateTime? editedAt) async {
    if (_schedule.entries.isNotEmpty || editedAt == null) return;
    _schedule = BudgetSchedule(BudgetSchedule.seed(kcal, editedAt));
    await _writeToDisk();
  }

  /// Records a budget edit, effective from the day it was made.
  Future<void> recordChange(int kcal, {DateTime? when}) async {
    _schedule = _schedule.upsert(kcal, when: when);
    await _writeToDisk();
  }

  /// Replaces the stored history with a merge result from the sync layer.
  ///
  /// An empty merge result is ignored rather than persisted: a pre-feature
  /// peer contributes no `hist:` fields, and writing the empty document back
  /// would discard this device's own history. Mirrors the same guard in
  /// `_sync._sync_budget`.
  Future<void> applyMerged(List<BudgetEntry> entries) async {
    if (entries.isEmpty) return;
    _schedule = BudgetSchedule(entries);
    await _writeToDisk();
  }

  /// Writes the whole in-memory schedule to the store.
  ///
  /// Deliberately *not* a read-modify-write. Edits arrive in bursts (a
  /// debounced settings field, a calendar save, and a sync write-back can
  /// overlap), and re-reading a date-keyed map per write would race and could
  /// drop entries; serializing the full in-memory state cannot.
  Future<void> _writeToDisk() async {
    await _store.write(
      documentName,
      jsonEncode(BudgetSchedule.encode(_schedule.entries)),
    );
  }
}
