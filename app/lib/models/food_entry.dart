/// A single logged meal entry, mirroring one `food_log.json` array element.
library;

import 'package:diet_guard_app/models/meal_component.dart';

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
    this.slot,
    this.hmac,
    this.components,
    this.deleted = false,
    this.imagePath,
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
    slot: json['slot'] as int?,
    hmac: json['hmac'] as String?,
    components: (json['components'] as List?)
        ?.cast<Map<String, dynamic>>()
        .map(MealComponent.fromJson)
        .toList(),
    deleted: json['deleted'] as bool? ?? false,
    imagePath: json['imagePath'] as String?,
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

  /// The meal-slot hour this entry satisfies (8/12/16/20), or null for a
  /// snack that counts toward calories but satisfies no slot.
  final int? slot;

  /// HMAC signature, present on entries that have passed through the PC's
  /// signing step. Never computed on the phone -- it never holds the key.
  final String? hmac;

  /// For a composite ("meal"-sourced) entry, each component's own macros.
  final List<MealComponent>? components;

  /// Tombstone flag: true once this entry has been undone. Kept (not
  /// physically removed) so a sync merge can't resurrect a stale copy.
  final bool deleted;

  /// Local file path to an attached photo, if any. Phone-local only --
  /// never read from a pulled remote copy and stripped before push.
  final String? imagePath;

  /// Returns the full local-storage representation, including [imagePath].
  Map<String, Object?> toLocalJson() => {
    ...toSyncJson(),
    if (imagePath != null) 'imagePath': imagePath,
  };

  /// Returns what gets pushed to this device's sync snapshot.
  ///
  /// Excludes [imagePath] (meaningless on another device) and [hmac] (the
  /// phone never computes one; the PC re-signs on merge regardless of
  /// origin, so an inbound signature would only be stripped there anyway).
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
    if (slot != null) 'slot': slot,
    if (components != null)
      'components': components!.map((c) => c.toJson()).toList(),
    if (deleted) 'deleted': true,
  };

  /// Returns a copy of this entry with [imagePath] replaced.
  FoodEntry copyWithImagePath(String? imagePath) => FoodEntry(
    id: id,
    time: time,
    desc: desc,
    grams: grams,
    kcal: kcal,
    proteinG: proteinG,
    carbsG: carbsG,
    fatG: fatG,
    source: source,
    slot: slot,
    hmac: hmac,
    components: components,
    deleted: deleted,
    imagePath: imagePath,
  );

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
    slot: slot,
    hmac: hmac,
    components: components,
    deleted: true,
    imagePath: imagePath,
  );
}
