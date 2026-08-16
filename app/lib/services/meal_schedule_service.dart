/// Persistence for the meal-schedule history.
///
/// Shaped exactly like [BudgetHistoryService]: a singleton over the platform
/// [DocumentStore], with a static getter that degrades to the default schedule
/// when uninitialised so widget tests that never call [init] still render.
///
/// Mirrors the storage half of `diet_guard/_meal_schedule_store.py`.
library;

import 'dart:convert';

import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/services/document_store.dart';
import 'package:diet_guard_app/services/document_store_factory.dart';
import 'package:diet_guard_app/services/meal_schedule_history.dart';
import 'package:flutter/foundation.dart';

/// Singleton owning the meal-schedule history document.
class MealScheduleService {
  MealScheduleService._(this._store);

  /// Document name this service owns.
  static const documentName = 'meal_schedule.json';

  static MealScheduleService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static MealScheduleService get instance => _instance!;

  /// True when [init]/[initForTesting]/[resetForTesting] has run.
  static bool get isInitialized => _instance != null;

  /// The schedule in force today, or the default when uninitialised.
  ///
  /// This is the impure edge every `slot.dart` caller resolves through; the
  /// slot arithmetic itself stays a pure function of its arguments.
  static MealSchedule get current =>
      _instance?._history.forDay(_todayKey()) ?? kDefaultSchedule;

  /// The whole stored history, for the sync layer and past-day lookups.
  static MealScheduleHistory get history =>
      _instance?._history ?? MealScheduleHistory.empty;

  /// When this device last set the schedule, or null if it never has.
  ///
  /// Null is what tells the sync layer this device has nothing of its own to
  /// contribute, rather than silently syncing the unset default.
  static DateTime? get updatedAt => _instance?._updatedAt;

  final DocumentStore _store;
  MealScheduleHistory _history = MealScheduleHistory.empty;
  DateTime? _updatedAt;

  /// Initialises the singleton against the platform document store.
  static Future<MealScheduleService> init() async {
    if (_instance != null) return _instance!;
    // Resolving the platform store is a plugin call (path_provider /
    // IndexedDB), not reachable from `flutter test`.
    // coverage:ignore-start
    final svc = MealScheduleService._(await openDocumentStore());
    // coverage:ignore-end
    await svc._load();
    _instance = svc;
    return svc;
  }

  /// Resets the singleton so [init] can be called again in tests.
  @visibleForTesting
  static void resetForTesting({DocumentStore? store}) {
    _instance = store == null ? null : MealScheduleService._(store);
  }

  /// Initialises from [store], calling the loader, for use in unit tests.
  @visibleForTesting
  static Future<MealScheduleService> initForTesting(DocumentStore store) async {
    final svc = MealScheduleService._(store);
    await svc._load();
    _instance = svc;
    return svc;
  }

  Future<void> _load() async {
    final raw = await _store.read(documentName);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      _history = MealScheduleHistory(MealScheduleHistory.parse(decoded));
      final stamp = decoded is Map ? decoded['t'] : null;
      _updatedAt = stamp is String ? DateTime.tryParse(stamp) : null;
    } on FormatException {
      // Ignore parse errors: no history means "use the default schedule",
      // which is exactly the pre-feature behaviour.
    }
  }

  /// Records a schedule edit, effective from the day it was made.
  ///
  /// Seeds the default at the epoch first, so past days keep the four-meal
  /// schedule they were actually judged against.
  Future<void> recordChange(MealSchedule schedule, {DateTime? when}) async {
    final moment = when ?? DateTime.now();
    _history = _history.seedDefault().upsert(schedule, when: moment);
    _updatedAt = moment;
    await _writeToDisk();
  }

  /// Replaces the stored history with a merge result from the sync layer.
  ///
  /// An empty merge result is ignored rather than persisted: a pre-feature
  /// peer contributes no `sched:` fields, and writing the empty document back
  /// would discard this device's own history.
  Future<void> applyMerged(
    List<ScheduleEntry> entries, {
    DateTime? updatedAt,
  }) async {
    if (entries.isEmpty) return;
    _history = MealScheduleHistory(entries);
    // The winner's stamp is persisted verbatim, not "now", so re-syncing an
    // unchanged history is idempotent.
    if (updatedAt != null) _updatedAt = updatedAt;
    await _writeToDisk();
  }

  /// Writes the whole in-memory history to the store.
  ///
  /// Deliberately *not* a read-modify-write, for the same reason as
  /// [BudgetHistoryService]: edits arrive in bursts and re-reading a
  /// date-keyed map per write could drop entries.
  Future<void> _writeToDisk() async {
    final document = MealScheduleHistory.encode(_history.entries);
    final stamp = _updatedAt;
    if (stamp != null) document['t'] = stamp.toIso8601String();
    await _store.write(documentName, jsonEncode(document));
  }
}

String _todayKey() {
  final now = DateTime.now();
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '${now.year}-$month-$day';
}
