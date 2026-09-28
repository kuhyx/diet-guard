/// The Body document's parts: stamped values, dated entries, parsers.
///
/// Split out of `body_document.dart` for the 250-line cap; that file
/// re-exports this one, so importers see no change. Parsing is tolerant: a
/// malformed part is dropped (null), never raised.
library;

/// A value and the ISO time it was last edited.
class Stamped {
  /// Creates a stamped value.
  const Stamped(this.value, this.t);

  /// The value.
  final Object? value;

  /// ISO-8601 edit time.
  final String t;
}

/// One day's weight. [kg] null is a tombstone (a deleted day).
class WeightEntry {
  /// Creates an entry.
  const WeightEntry({required this.kg, required this.src, required this.t});

  /// Kilograms, or null when deleted.
  final double? kg;

  /// `phone`, `manual` or `init`.
  final String src;

  /// ISO-8601 edit time.
  final String t;

  /// JSON form of the local document.
  Map<String, Object?> toJson() => {'kg': kg, 'src': src, 't': t};
}

/// One day's body fat %. [pct] null is a tombstone (a deleted day).
class BodyFatEntry {
  /// Creates an entry.
  const BodyFatEntry({required this.pct, required this.t});

  /// Percent, or null when deleted.
  final double? pct;

  /// ISO-8601 edit time.
  final String t;

  /// JSON form of the local document.
  Map<String, Object?> toJson() => {'pct': pct, 't': t};
}

/// One day's steps outside workouts, as the phone read them.
class StepsEntry {
  /// Creates an entry.
  const StepsEntry({required this.n, required this.t});

  /// Step count.
  final int n;

  /// ISO-8601 edit time.
  final String t;

  /// JSON form of the local document.
  Map<String, Object?> toJson() => {'n': n, 't': t};
}

/// Workouts published by the PC.
class ActivityData {
  /// Creates the published activity.
  const ActivityData({required this.sessions, required this.t});

  /// Raw session objects, as on the wire.
  final List<Object?> sessions;

  /// ISO-8601 time the PC last changed them.
  final String t;
}

/// Parses an ISO stamp to epoch milliseconds; unparsable -> 0 (the epoch).
int stampMillis(String t) => DateTime.tryParse(t)?.millisecondsSinceEpoch ?? 0;

/// Whether [raw] is a usable weight in kilograms.
bool plausibleKg(Object? raw) => raw is num && raw >= 20 && raw <= 400;

/// Body fat below/above this (%) is a typo, not a measurement.
const double minBodyFat = 3;

/// Upper bound of a plausible body fat %.
const double maxBodyFat = 70;

/// Whether [raw] is a usable body fat %.
bool plausibleBodyFat(Object? raw) =>
    raw is num && raw >= minBodyFat && raw <= maxBodyFat;

final RegExp _dateKey = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Whether [raw] is a `YYYY-MM-DD` date key.
bool isDateKey(Object? raw) => raw is String && _dateKey.hasMatch(raw);

/// Parses a weight value `{kg, src}` stamped [t], or null when malformed.
///
/// `kg` must be null (a tombstone) or a plausible number.
WeightEntry? parseWeightValue(Object? value, Object? t) {
  if (value is! Map || t is! String) return null;
  final kg = value['kg'];
  if (kg != null && !plausibleKg(kg)) return null;
  final src = value['src'];
  return WeightEntry(
    kg: (kg as num?)?.toDouble(),
    src: src is String ? src : 'manual',
    t: t,
  );
}

/// Parses a body-fat value `{pct}` stamped [t], or null when malformed.
///
/// `pct` must be null (a tombstone) or a plausible number.
BodyFatEntry? parseBodyFatValue(Object? value, Object? t) {
  if (value is! Map || t is! String) return null;
  final pct = value['pct'];
  if (pct != null && !plausibleBodyFat(pct)) return null;
  return BodyFatEntry(pct: (pct as num?)?.toDouble(), t: t);
}

/// Parses a steps value `{n}` stamped [t], or null when malformed.
StepsEntry? parseStepsValue(Object? value, Object? t) {
  if (value is! Map || t is! String) return null;
  final n = value['n'];
  if (n is! num || n < 0) return null;
  return StepsEntry(n: n.toInt(), t: t);
}
