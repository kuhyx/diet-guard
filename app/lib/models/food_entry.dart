/// A single logged meal entry, mirroring one `food_log.json` array element.
library;

import 'package:diet_guard_app/models/meal_component.dart';
import 'package:diet_guard_app/models/meal_schedule.dart';
import 'package:diet_guard_app/models/slot.dart';

/// One logged meal, as stored in `food_log.json` under its date key.
///
/// Field names and shapes mirror diet_guard's `_state.log_meal` entry
/// exactly, so this app's local storage *is* the wire format -- no
/// translation layer is needed when syncing with the PC app.
class FoodEntry {
  /// Creates a [FoodEntry] from its stored fields.
  const FoodEntry({
    required this.time,
    required this.desc,
    required this.grams,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.source,
    this.id,
    this.slotMinute,
    this.hmac,
    this.components,
    this.deleted = false,
  });

  /// Builds a [FoodEntry] from its JSON map representation.
  ///
  /// Missing/non-numeric macro fields default to 0, mirroring
  /// `_state._entry_float`'s tolerance of a hand-edited or partial entry.
  factory FoodEntry.fromJson(Map<String, dynamic> json) => FoodEntry(
    id: json['id'] as String?,
    time: json['time'] as String? ?? '',
    desc: json['desc'] as String? ?? '',
    grams: (json['grams'] as num?)?.toDouble() ?? 0,
    kcal: (json['kcal'] as num?)?.toDouble() ?? 0,
    proteinG: (json['protein_g'] as num?)?.toDouble() ?? 0,
    carbsG: (json['carbs_g'] as num?)?.toDouble() ?? 0,
    fatG: (json['fat_g'] as num?)?.toDouble() ?? 0,
    source: json['source'] as String? ?? 'manual',
    slotMinute: entrySlotMinute(json),
    hmac: json['hmac'] as String?,
    components: (json['components'] as List?)
        ?.cast<Map<String, dynamic>>()
        .map(MealComponent.fromJson)
        .toList(),
    deleted: json['deleted'] as bool? ?? false,
  );

  /// Stable identity for sync merge (UUID v4). Null only for legacy entries
  /// written before this field existed.
  final String? id;

  /// ISO-8601 local timestamp with second precision, kept as a opaque
  /// string (not parsed to [DateTime]) so it round-trips byte-for-byte --
  /// the same field the PC's HMAC is computed over.
  final String time;

  /// The user's free-text meal description.
  final String desc;

  /// Portion weight in grams (0 if unknown).
  final double grams;

  /// Calories for this entry.
  final double kcal;

  /// Protein in grams.
  final double proteinG;

  /// Carbohydrate in grams.
  final double carbsG;

  /// Fat in grams.
  final double fatG;

  /// Provenance label (e.g. `"manual"`, `"food bank"`, `"meal"`).
  final String source;

  /// The meal-slot minute of day this entry was logged against (480 for
  /// 08:00, 435 for 07:15), or null for a snack that satisfies no slot.
  ///
  /// A *recorded* minute, not a live checkpoint: which slot it satisfies is
  /// decided at read time by `satisfiedSlots`, so an entry written under an
  /// older schedule still counts after the schedule moves.
  ///
  /// Read through `entrySlotMinute` (`slot_min` wins, else `slot` x 60) and
  /// written back through `slotFields`, so a PC entry carrying `slot_min`
  /// survives a round trip through this device. Keeping only the hour would
  /// make every edit or tombstone republish a stripped copy, and the merge
  /// would spread that lossy copy back to the PC.
  ///
  /// Nothing writes null any more -- the "Snack" chip was removed on
  /// 2026-08-14 and every remaining writer resolves a concrete slot through
  /// `slotForLog`/`slot_for_log` -- but entries already on disk and arriving
  /// over sync still carry no `slot` key, so the null case and every
  /// `slot != null` filter built on it are load-bearing. Dropping them would
  /// make those historical entries retroactively satisfy meal slots.
  final int? slotMinute;

  /// HMAC signature, present on entries that have passed through the PC's
  /// signing step. Never computed on the phone -- it never holds the key.
  final String? hmac;

  /// For a composite ("meal"-sourced) entry, each component's own macros.
  final List<MealComponent>? components;

  /// Tombstone flag: true once this entry has been undone. Kept (not
  /// physically removed) so a sync merge can't resurrect a stale copy.
  final bool deleted;

  /// Returns the full local-storage representation.
  ///
  /// Identical to [toSyncJson] now that nothing is device-local: every field
  /// a device stores is a field it shares.
  Map<String, Object?> toLocalJson() => toSyncJson();

  /// Returns what gets pushed to this device's sync snapshot.
  ///
  /// Excludes [hmac] (the phone never computes one; the PC re-signs on merge
  /// regardless of origin, so an inbound signature would only be stripped
  /// there anyway).
  Map<String, Object?> toSyncJson() => {
    if (id != null) 'id': id,
    'time': time,
    'desc': desc,
    'grams': grams,
    'kcal': kcal,
    'protein_g': proteinG,
    'carbs_g': carbsG,
    'fat_g': fatG,
    'source': source,
    ..._slotJson(slotMinute),
    if (components != null)
      'components': components!.map((c) => c.toJson()).toList(),
    if (deleted) 'deleted': true,
  };

  /// Returns a copy of this entry tombstoned (`deleted: true`).
  FoodEntry copyWithDeleted() => FoodEntry(
    id: id,
    time: time,
    desc: desc,
    grams: grams,
    kcal: kcal,
    proteinG: proteinG,
    carbsG: carbsG,
    fatG: fatG,
    source: source,
    slotMinute: slotMinute,
    hmac: hmac,
    components: components,
    deleted: true,
  );
}

/// Returns the wire fields for [minute], total over every value it can hold.
///
/// [slotFields] throws outside the day, but [entrySlotMinute] does not
/// range-check what a peer sent. A single `slot: 24` arriving over sync would
/// otherwise make every later `writeLog` throw -- one bad entry blocking all
/// logging. Such a value is echoed back unrepaired, by the same whole-hour
/// rule (so a legacy `slot: 24` stays byte-identical), with `~/` only on a
/// non-negative operand -- a negative value travels as `slot_min` alone.
Map<String, int> _slotJson(int? minute) {
  if (minute == null) return const {};
  if (minute >= 0 && minute < kMinutesPerDay) return slotFields(minute);
  return {
    if (minute >= 0) 'slot': minute ~/ 60,
    if (minute < 0 || minute % 60 != 0) 'slot_min': minute,
  };
}
