/// Local-time formatting that matches diet_guard's Python ISO format.
library;

/// Returns [now] as an ISO-8601 string with a fixed local UTC offset and
/// second precision, matching Python's
/// `now_local().isoformat(timespec="seconds")`, e.g.
/// `"2026-06-22T15:08:11+02:00"`.
///
/// Dart's own [DateTime.toIso8601String] omits the UTC offset for a local
/// (non-UTC) [DateTime], so this fills that gap to keep the `time` field
/// byte-comparable with entries the PC app writes.
String isoLocalSeconds(DateTime now) {
  final offset = now.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final absOffset = offset.abs();
  String two(int value) => value.toString().padLeft(2, '0');
  String four(int value) => value.toString().padLeft(4, '0');
  final offsetHours = two(absOffset.inHours);
  final offsetMinutes = two(absOffset.inMinutes.remainder(60));
  return '${four(now.year)}-${two(now.month)}-${two(now.day)}'
      'T${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
      '$sign$offsetHours:$offsetMinutes';
}

/// Returns [now]'s local calendar date as `YYYY-MM-DD`.
///
/// Local, not UTC: mirrors `_state._today()` -- "what I ate today" is a
/// local-calendar concept, so a meal eaten late in the evening must not
/// roll into tomorrow's total.
String localDateKey(DateTime now) => isoLocalSeconds(now).substring(0, 10);
