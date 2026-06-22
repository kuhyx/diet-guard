/// Local persistence for the food log, mirroring diet_guard's `_state.py`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/models/meal_component.dart';
import 'package:diet_guard_app/models/nutrition.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// The on-disk log shape: date key (`YYYY-MM-DD`) to that day's entries.
typedef DayLog = Map<String, List<FoodEntry>>;

/// Singleton service reading/writing `food_log.json` verbatim.
///
/// Stores plain JSON matching diet_guard's exact on-disk schema rather than
/// a SQL database: the canonical format already *is* this JSON (it is also
/// the sync payload, see Milestone 3), so a SQL schema would only add a
/// second representation to keep in lockstep for no query benefit --
/// autocomplete is small-corpus fuzzy string matching, not a relational
/// query.
class LogStorageService {
  LogStorageService._(this._file);

  static LogStorageService? _instance;

  /// Returns the initialized singleton; throws if [init] was not called.
  static LogStorageService get instance => _instance!;

  final File _file;

  /// Initializes the singleton, pointing at the app's documents directory
  /// (phone-sandboxed; no external-storage permission needed).
  static Future<LogStorageService> init() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    final svc = LogStorageService._(File(p.join(dir.path, 'food_log.json')));
    _instance = svc;
    return svc;
  }

  /// Resets the singleton so [init] can be called again in tests.
  ///
  /// When [testDir] is given, subsequent reads/writes go there instead of
  /// the real documents directory, so a test can never touch real data.
  @visibleForTesting
  static void resetForTesting({Directory? testDir}) {
    _instance = testDir == null
        ? null
        : LogStorageService._(File(p.join(testDir.path, 'food_log.json')));
  }

  /// Reads the full log, including tombstoned entries.
  ///
  /// Returns an empty log on a missing or unparsable file, mirroring
  /// `_state._read_raw_log`'s defensive read.
  Future<DayLog> readLog() async {
    if (!_file.existsSync()) return {};
    String raw;
    try {
      raw = await _file.readAsString();
    } on FileSystemException {
      return {};
    }
    Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      return {};
    }
    if (data is! Map) return {};
    final result = <String, List<FoodEntry>>{};
    for (final mapEntry in data.entries) {
      final key = mapEntry.key;
      final value = mapEntry.value;
      if (key is! String || value is! List<dynamic>) continue;
      result[key] = value
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => FoodEntry.fromJson(m.cast<String, dynamic>()))
          .toList();
    }
    return result;
  }

  /// Persists the full log to disk, creating the parent directory if
  /// needed, mirroring `_state._write_log`.
  Future<void> writeLog(DayLog log) async {
    await _file.parent.create(recursive: true);
    final encoded = <String, Object?>{
      for (final mapEntry in log.entries)
        mapEntry.key: mapEntry.value.map((e) => e.toLocalJson()).toList(),
    };
    await _file.writeAsString(jsonEncode(encoded));
  }

  /// Appends a signed-on-PC-eventually entry for [desc] to today's log.
  ///
  /// Mirrors `_state.log_meal`: always assigns a fresh `id`, never computes
  /// an `hmac` (the phone never holds the shared key -- the PC re-signs on
  /// merge, see Milestone 3).
  Future<FoodEntry> logMeal(
    String desc,
    Nutrition nutrition, {
    int? slot,
    List<MealComponent>? components,
    String? imagePath,
  }) async {
    final now = DateTime.now();
    final entry = FoodEntry(
      id: const Uuid().v4(),
      time: isoLocalSeconds(now),
      desc: desc,
      grams: nutrition.grams,
      kcal: nutrition.kcal,
      proteinG: nutrition.proteinG,
      carbsG: nutrition.carbsG,
      fatG: nutrition.fatG,
      source: nutrition.source,
      slot: slot,
      components: components,
      imagePath: imagePath,
    );
    final log = await readLog();
    log.putIfAbsent(localDateKey(now), () => []).add(entry);
    await writeLog(log);
    return entry;
  }

  /// Tombstones today's most recently logged, not-yet-undone entry.
  ///
  /// Mirrors `_state.undo_last_today`: marks the entry `deleted` in place
  /// rather than removing it, so a later sync merge can't resurrect a
  /// stale copy of the same entry from another device.
  Future<FoodEntry?> undoLastToday() async {
    final log = await readLog();
    final today = localDateKey(DateTime.now());
    final entries = log[today];
    if (entries == null || entries.isEmpty) return null;
    for (var i = entries.length - 1; i >= 0; i--) {
      if (entries[i].deleted) continue;
      final tombstoned = entries[i].copyWithDeleted();
      entries[i] = tombstoned;
      log[today] = entries;
      await writeLog(log);
      return tombstoned;
    }
    return null;
  }

  /// Returns today's non-tombstoned entries, mirrors `_state.today_entries`.
  Future<List<FoodEntry>> todayEntries() async {
    final log = await readLog();
    final entries = log[localDateKey(DateTime.now())] ?? const <FoodEntry>[];
    return entries.where((e) => !e.deleted).toList();
  }

  /// Returns every non-tombstoned entry across all days, newest first.
  ///
  /// Backs the history screen -- the only place that needs to see more than
  /// "today".
  Future<List<FoodEntry>> allEntriesNewestFirst() async {
    final log = await readLog();
    final entries = [
      for (final dayEntries in log.values)
        ...dayEntries.where((e) => !e.deleted),
    ]..sort((a, b) {
      final aTime = DateTime.tryParse(a.time);
      final bTime = DateTime.tryParse(b.time);
      if (aTime == null || bTime == null) return 0;
      return bTime.compareTo(aTime);
    });
    return entries;
  }

  /// Returns today's total calories, mirrors `_state.today_total_kcal`.
  Future<double> todayTotalKcal() async {
    final entries = await todayEntries();
    var total = 0.0;
    for (final entry in entries) {
      total += entry.kcal;
    }
    return double.parse(total.toStringAsFixed(1));
  }

  /// Returns the slot hours already satisfied today, mirrors
  /// `_state.logged_slots_today`.
  Future<Set<int>> loggedSlotsToday() async {
    final entries = await todayEntries();
    return entries
        .where((e) => e.slot != null)
        .map((e) => e.slot!)
        .toSet();
  }
}
