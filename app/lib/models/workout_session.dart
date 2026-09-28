/// One published workout, as the PC syncs it in the Body document.
///
/// Split out of `services/activity_kcal.dart` for the 250-line cap; that
/// file re-exports it, so importers see no change. Parsing is tolerant: a
/// malformed session is dropped, an unparsable time reads as null.
library;

/// One workout, reduced to what the energy formulas need.
class Session {
  /// Creates a session.
  const Session({
    required this.day,
    required this.kind,
    required this.minutes,
    required this.km,
    required this.label,
    required this.source,
    this.start,
    this.end,
  });

  /// Parses the synced wire object (`day, kind, min, km, label, src`), or
  /// null when it is malformed.
  static Session? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final day = raw['day'];
    final kind = raw['kind'];
    final minutes = raw['min'];
    final km = raw['km'];
    if (day is! String || kind is! String || minutes is! num) return null;
    if (km != null && km is! num) return null;
    return Session(
      day: day,
      kind: kind,
      minutes: minutes.toDouble(),
      km: (km as num?)?.toDouble(),
      label: raw['label'] is String ? raw['label'] as String : kind,
      source: raw['src'] is String ? raw['src'] as String : '',
      start: _stampOrNull(raw['start']),
      end: _stampOrNull(raw['end']),
    );
  }

  /// Local `YYYY-MM-DD` the workout happened on.
  final String day;

  /// `strength`, `run`, `walk`, `cycle` or `other`.
  final String kind;

  /// Duration in minutes.
  final double minutes;

  /// Distance, or null when the source has none.
  final double? km;

  /// Human description.
  final String label;

  /// Where it came from (`runnerup`, `screen-locker`).
  final String source;

  /// ISO start time, when the source knows it.
  final String? start;

  /// ISO end time, when the source knows it. The phone drops Health
  /// Connect steps inside `start..end`, so a walk is not counted twice.
  final String? end;
}

/// An ISO time string, or null when absent or unparsable.
String? _stampOrNull(Object? value) =>
    value is String && DateTime.tryParse(value) != null ? value : null;
