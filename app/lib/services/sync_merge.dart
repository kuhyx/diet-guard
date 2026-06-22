/// Pure log-merge logic for diet_guard's cross-device sync.
///
/// No I/O here -- this module is unit-testable purely on in-memory [DayLog]
/// values. Mirrored test-for-test against the Python original
/// (`diet_guard/_sync_merge.py`), so the merge algorithm canonically agrees
/// on both sides of the sync.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';

/// A dedup key: `('id', <uuid>)` for any entry with one, else
/// `('legacy', (time, desc))` for a pre-id entry written before this field
/// existed -- two devices that both already had that same legacy entry would
/// otherwise end up with two copies of it after a merge.
typedef _MergeKey = (String, Object);

_MergeKey _entryKey(FoodEntry entry) {
  final id = entry.id;
  if (id != null && id.isNotEmpty) return ('id', id);
  return ('legacy', (entry.time, entry.desc));
}

/// Returns true if [candidate] should replace [existing] for one key.
///
/// A tombstone always wins over a non-tombstoned copy of the same entry --
/// deletion is sticky, so a stale pre-undo copy pulled from another device
/// can never resurrect something the user explicitly removed. Otherwise,
/// keep whichever copy was seen first: two copies of the same id are
/// expected to be identical in their macros/desc (the body is never mutated
/// after creation, only `deleted`/`hmac`), so which one survives does not
/// change the merged result's content.
bool _tombstoneWins(FoodEntry candidate, FoodEntry existing) =>
    candidate.deleted && !existing.deleted;

/// Returns the union of [local] and [remote], tombstones winning by id.
///
/// Commutative and idempotent: `mergeLogs(a, b) == mergeLogs(b, a)` and
/// `mergeLogs(x, x) == x` (for an `x` with no duplicate keys), so pull-order
/// between devices never matters and a repeated sync tick is a no-op. Each
/// entry is re-bucketed under its own `time`'s date rather than the date key
/// it arrived under, so a merge can't silently leave an entry filed under
/// the wrong day.
DayLog mergeLogs(DayLog local, DayLog remote) {
  final byKey = <_MergeKey, FoodEntry>{};
  for (final dayLog in [local, remote]) {
    for (final entries in dayLog.values) {
      for (final entry in entries) {
        final key = _entryKey(entry);
        final existing = byKey[key];
        if (existing == null || _tombstoneWins(entry, existing)) {
          byKey[key] = entry;
        }
      }
    }
  }

  final merged = <String, List<FoodEntry>>{};
  for (final entry in byKey.values) {
    final dateKey = entry.time.length >= 10
        ? entry.time.substring(0, 10)
        : entry.time;
    merged.putIfAbsent(dateKey, () => []).add(entry);
  }
  for (final entries in merged.values) {
    entries.sort((a, b) => a.time.compareTo(b.time));
  }
  return merged;
}
