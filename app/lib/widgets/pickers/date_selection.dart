/// The date picker's selection rules, kept free of widgets so each rule is a
/// plain unit test: bounds clamp, the two-tap range, the month/year day clamp.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart' show DateTimeRange, DateUtils;

/// What the date picker has chosen, and which month it is showing.
///
/// Every date is date-only (midnight local); days are stepped with
/// `DateTime(y, m, d + n)`, never a `Duration`, so DST cannot shift a day.
class DateSelection {
  /// A single-date selection starting on [initial], clamped into bounds.
  DateSelection.single({
    required DateTime first,
    required DateTime last,
    DateTime? initial,
  }) : first = DateUtils.dateOnly(first),
       last = DateUtils.dateOnly(last),
       range = false {
    start = _clamp(initial ?? DateTime.now());
    _init(start!);
  }

  /// A two-tap range selection. A preset [initial] range counts as both taps
  /// done, so it can be confirmed at once.
  DateSelection.range({
    required DateTime first,
    required DateTime last,
    DateTimeRange? initial,
  }) : first = DateUtils.dateOnly(first),
       last = DateUtils.dateOnly(last),
       range = true {
    if (initial != null) {
      start = _clamp(initial.start);
      end = _clamp(initial.end);
    }
    _init(start ?? _clamp(DateTime.now()));
  }

  /// Earliest selectable day.
  final DateTime first;

  /// Latest selectable day.
  final DateTime last;

  /// Whether this is the two-tap range mode.
  final bool range;

  /// The chosen day (single mode) or the range start.
  DateTime? start;

  /// The range end; null until the second tap.
  DateTime? end;

  /// The keyboard cursor; equals [start] in single mode.
  late DateTime cursor;

  /// Shown year.
  late int year;

  /// Shown month, 1-12.
  late int month;

  void _init(DateTime at) {
    cursor = at;
    year = at.year;
    month = at.month;
  }

  DateTime _clamp(DateTime day) {
    final d = DateUtils.dateOnly(day);
    if (d.isBefore(first)) return first;
    return d.isAfter(last) ? last : d;
  }

  /// Whether [day] lies within the bounds.
  bool allows(DateTime day) => !day.isBefore(first) && !day.isAfter(last);

  /// Whether any day of month [m] of year [y] lies within the bounds.
  bool monthAllowed(int y, int m) =>
      !DateTime(y, m + 1, 0).isBefore(first) && !DateTime(y, m).isAfter(last);

  /// Whether the check may be pressed: always in single mode, after both
  /// taps in range mode.
  bool get canConfirm => !range || end != null;

  /// The range chosen so far, once both ends are set.
  DateTimeRange? get dateRange =>
      end == null ? null : DateTimeRange(start: start!, end: end!);

  /// A tap on [day]. Out-of-range days are inert. In range mode: the first
  /// tap sets the start, the second the end (in either order), a third
  /// restarts from [day].
  void tap(DateTime day) {
    if (!allows(day)) return;
    cursor = day;
    if (!range) {
      start = day;
    } else if (start == null || end != null) {
      start = day;
      end = null;
    } else if (day.isBefore(start!)) {
      end = start;
      start = day;
    } else {
      end = day;
    }
  }

  /// Moves the cursor by [days], following it into another month. Stops at
  /// the bounds. In single mode the selection moves with it.
  void moveCursor(int days) {
    final day = DateTime(cursor.year, cursor.month, cursor.day + days);
    if (!allows(day)) return;
    _init(day);
    if (!range) start = day;
  }

  /// Shows month [m] of the shown year.
  void showMonth(int m) => _show(year, m);

  /// Shows year [y], keeping the month where the bounds allow.
  void showYear(int y) => _show(y, month);

  /// Shows ([y], [m]), pulling the month into bounds and the cursor day to
  /// the new month's last day where it is shorter. A range's chosen ends
  /// never move.
  void _show(int y, int m) {
    var shown = m;
    if (y == first.year && shown < first.month) shown = first.month;
    if (y == last.year && shown > last.month) shown = last.month;
    final day = math.min(cursor.day, DateUtils.getDaysInMonth(y, shown));
    year = y;
    month = shown;
    cursor = _clamp(DateTime(y, shown, day));
    if (!range) start = cursor;
  }
}
