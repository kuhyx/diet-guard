/// The day grid: one month of numerals, Monday first, with no weekday header.
///
/// One widget serves the single-date and the range picker; the mode lives in
/// [DateSelection], so the range picker is a mode of this grid, not a copy.
library;

import 'package:diet_guard_app/widgets/pickers/date_selection.dart';
import 'package:diet_guard_app/widgets/pickers/numeral_cell.dart';
import 'package:flutter/material.dart';

/// Six rows of seven: every month fits, and the dialog never changes height.
const int kGridCells = 42;

/// The shown month of [selection] as a numeral grid.
///
/// Today has a ring; weekends are dimmed with a dot; out-of-range days are
/// dimmed further and inert. The chosen day, or both range ends, are filled;
/// the days of a range are shaded.
class DateGrid extends StatelessWidget {
  /// Creates a [DateGrid].
  const DateGrid({
    required this.selection,
    required this.today,
    required this.onTap,
    this.showCursor = false,
    super.key,
  });

  /// The selection being edited (read only here).
  final DateSelection selection;

  /// Today's date, ringed.
  final DateTime today;

  /// Called with a tapped in-range day.
  final ValueChanged<DateTime> onTap;

  /// Whether to outline the keyboard cursor (the grid has focus).
  final bool showCursor;

  bool _inBand(DateTime day) {
    final start = selection.start;
    final end = selection.end;
    if (start == null || end == null || start == end) return false;
    return !day.isBefore(start) && !day.isAfter(end);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final year = selection.year;
    final month = selection.month;
    final lead = DateTime(year, month).weekday - DateTime.monday;
    final days = DateUtils.getDaysInMonth(year, month);
    return numeralRows(7, [
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (var d = 1; d <= days; d++) _cell(DateTime(year, month, d), l10n),
      for (var i = lead + days; i < kGridCells; i++) const SizedBox.shrink(),
    ]);
  }

  Widget _cell(DateTime day, MaterialLocalizations l10n) => NumeralCell(
    key: ValueKey(day),
    label: '${day.day}',
    semanticLabel: l10n.formatFullDate(day),
    onTap: () => onTap(day),
    enabled: selection.allows(day),
    selected: day == selection.start || day == selection.end,
    band: _inBand(day),
    ring: DateUtils.isSameDay(day, today),
    dot: day.weekday >= DateTime.saturday,
    focused: showCursor && day == selection.cursor,
  );
}
