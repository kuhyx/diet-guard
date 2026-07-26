/// Effective-from history of the daily kcal budget.
///
/// Pure mirror of `diet_guard/_budget_history.py` -- keep the two in sync, a
/// divergence means the PC and the phone classify the same day differently.
///
/// The budget is a single freely-editable number, but *classifying a past day*
/// must use the budget that applied on that day; otherwise lowering the budget
/// silently reclassifies months of history, breaking the adherence streak and
/// the year-to-date tally for days that were adherent at the time.
library;

import 'package:flutter/foundation.dart';

/// The budget assumed when nothing has ever been set on this device.
const int kDefaultDailyKcalGoal = 2200;

/// The effective-from date the migration seeds, so the pre-history budget
/// covers every day that was ever logged.
const String kEpochDay = '1970-01-01';

const String _epochIso = '1970-01-01T00:00:00.000Z';

const int _historyVersion = 1;

/// One budget value and the date it started applying.
@immutable
class BudgetEntry {
  /// Creates a [BudgetEntry].
  const BudgetEntry({
    required this.effectiveFrom,
    required this.kcal,
    required this.editedAt,
  });

  /// Parses one stored entry, or null when it is malformed.
  static BudgetEntry? tryFromJson(String day, Object? raw) {
    if (raw is! Map) return null;
    final kcal = raw['b'];
    if (kcal is! int) return null;
    final editedAt = raw['t'];
    return BudgetEntry(
      effectiveFrom: day,
      kcal: kcal,
      editedAt: editedAt is String ? editedAt : _epochIso,
    );
  }

  /// `YYYY-MM-DD`; the first day this value applies to.
  final String effectiveFrom;

  /// The daily budget in kcal from [effectiveFrom] onward.
  final int kcal;

  /// Local ISO-8601 timestamp of the edit that created this entry, used to
  /// derive a deterministic Hlc for the sync merge.
  final String editedAt;

  /// Serializes to the stored entry shape.
  Map<String, dynamic> toJson() => {'b': kcal, 't': editedAt};

  @override
  bool operator ==(Object other) =>
      other is BudgetEntry &&
      other.effectiveFrom == effectiveFrom &&
      other.kcal == kcal &&
      other.editedAt == editedAt;

  @override
  int get hashCode => Object.hash(effectiveFrom, kcal, editedAt);

  @override
  String toString() => 'BudgetEntry($effectiveFrom, $kcal, $editedAt)';
}

/// The budget as a function of the day, with a fallback for empty history.
class BudgetSchedule {
  /// Creates a [BudgetSchedule] from [entries], ascending by effective-from.
  const BudgetSchedule(this.entries, {this.fallback = kDefaultDailyKcalGoal});

  /// A schedule with no history at all; every day resolves to [fallback].
  static const empty = BudgetSchedule(<BudgetEntry>[]);

  /// Ascending by [BudgetEntry.effectiveFrom].
  final List<BudgetEntry> entries;

  /// Used when no entry applies -- an unset device, or a day before the
  /// earliest entry. The second case does not arise in practice, since the
  /// migration always seeds [kEpochDay].
  final int fallback;

  /// Returns the budget that applied on [day] (a `YYYY-MM-DD` key).
  int forDay(String day) {
    var result = fallback;
    for (final entry in entries) {
      if (entry.effectiveFrom.compareTo(day) > 0) break;
      result = entry.kcal;
    }
    return result;
  }

  /// Returns the budget in force today.
  int get current => forDay(_dateKey(DateTime.now()));

  /// Returns this schedule with [when]'s date set to [kcal].
  ///
  /// Keyed on the date, so editing the budget twice in one day replaces that
  /// day's entry rather than accumulating duplicates.
  BudgetSchedule upsert(int kcal, {DateTime? when}) {
    final moment = when ?? DateTime.now();
    final day = _dateKey(moment);
    final kept = entries.where((e) => e.effectiveFrom != day).toList()
      ..add(
        BudgetEntry(
          effectiveFrom: day,
          kcal: kcal,
          editedAt: moment.toIso8601String(),
        ),
      )
      ..sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));
    return BudgetSchedule(kept, fallback: fallback);
  }

  /// Parses a stored history document, tolerating anything malformed.
  ///
  /// A corrupt or unrecognised history degrades to "no history", which
  /// callers already handle by falling back to the current scalar budget.
  static List<BudgetEntry> parse(Object? raw) {
    if (raw is! Map || raw['v'] != _historyVersion) return const [];
    final stored = raw['e'];
    if (stored is! Map) return const [];
    final entries = <BudgetEntry>[];
    for (final day in stored.keys) {
      final entry = BudgetEntry.tryFromJson('$day', stored[day]);
      if (entry != null) entries.add(entry);
    }
    entries.sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));
    return entries;
  }

  /// Serializes [entries] to the stored document shape.
  static Map<String, dynamic> encode(List<BudgetEntry> entries) => {
    'v': _historyVersion,
    'e': {for (final e in entries) e.effectiveFrom: e.toJson()},
  };

  /// Returns the one-entry history that grandfathers an existing budget.
  ///
  /// The pre-history budget is treated as having applied since [kEpochDay],
  /// so every already-logged day keeps the value it was actually judged
  /// against. Reuses the caller's own [editedAt] rather than "now", which is
  /// what lets two devices seed independently and still converge on the same
  /// value at the same Hlc wall time.
  static List<BudgetEntry> seed(int kcal, DateTime? editedAt) => [
    BudgetEntry(
      effectiveFrom: kEpochDay,
      kcal: kcal,
      editedAt: editedAt?.toIso8601String() ?? _epochIso,
    ),
  ];
}

String _dateKey(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
