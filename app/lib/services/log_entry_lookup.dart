/// Id lookups over the food log, tombstones included.
///
/// Split out of `log_storage_service.dart` for the repo's 250-line cap.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/models/local_time.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';

/// Returns the entry with [id] anywhere in [log], deleted or not, else null.
///
/// Tombstones count on purpose: an entry the user undid must keep blocking
/// its own id, or a repeat open would log it again.
FoodEntry? findEntryById(DayLog log, String id) {
  for (final entries in log.values) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
  }
  return null;
}

/// Id-keyed writes and reads on [LogStorageService].
extension LogEntryLookup on LogStorageService {
  /// The entry with [id], deleted or not, else null.
  Future<FoodEntry?> findEntry(String id) async =>
      findEntryById(await readLog(), id);

  /// Every id in the log, tombstones included.
  Future<Set<String>> allEntryIds() async => {
    for (final entries in (await readLog()).values)
      for (final entry in entries) ?entry.id,
  };

  /// Adds [entry] unless one with its id exists (live or tombstoned), and
  /// returns whichever copy the log holds.
  ///
  /// For an entry another device wrote under an id chosen here, such as a
  /// Claude-logged meal: the sync merge delivers the same record, so this only
  /// shows it a tick earlier and can never double it.
  Future<FoodEntry> addIfAbsent(FoodEntry entry) async {
    final log = await readLog();
    final id = entry.id;
    if (id != null) {
      final existing = findEntryById(log, id);
      if (existing != null) return existing;
    }
    final dayKey = entry.time.length >= 10
        ? entry.time.substring(0, 10)
        : localDateKey(DateTime.now());
    log.putIfAbsent(dayKey, () => []).add(entry);
    await writeLog(log);
    return entry;
  }
}
