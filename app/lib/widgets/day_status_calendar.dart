/// Monthly calendar colored by daily budget-adherence status.
library;

import 'package:diet_guard_app/models/day_status.dart';
import 'package:flutter/material.dart';

/// Monthly calendar widget that colors each day by its [DayStatus].
///
/// Mirrors the diet_guard gate's calendar tab (`_gatelock_calendar.py` /
/// `_calendar_view.py`): not-logged renders as a black cell with a visible
/// outline (so it doesn't vanish into the dark background); a day after
/// [today] -- nothing has happened yet to judge -- renders neutrally,
/// never as a false "not logged" black cell.
class DayStatusCalendar extends StatelessWidget {
  /// Creates a [DayStatusCalendar].
  const DayStatusCalendar({
    required this.statusByDate,
    required this.month,
    required this.today,
    required this.onPrevMonth,
    required this.onNextMonth,
    this.onDaySelected,
    super.key,
  });

  /// Per-day status, keyed `YYYY-MM-DD`. A past-or-today date absent from
  /// this map is treated as [DayStatus.notLogged].
  final Map<String, DayStatus> statusByDate;

  /// Only the year and month of this DateTime are used.
  final DateTime month;

  /// The reference "today"; days after this render neutrally.
  final DateTime today;

  /// Called when the user taps the previous-month chevron.
  final VoidCallback onPrevMonth;

  /// Called when the user taps the next-month chevron.
  final VoidCallback onNextMonth;

  /// Called with a day's date when the user taps that day's cell.
  ///
  /// Null disables tapping (cells render but do not respond). A cell
  /// outside the displayed month is never tappable regardless.
  final void Function(DateTime day)? onDaySelected;

  static const _weekHeaders = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String _dateKey(int year, int m, int day) =>
      '$year-${m.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  /// Returns the status to render for [year]/[m]/[day], or null for a
  /// future day (nothing to judge yet).
  DayStatus? _statusFor(int year, int m, int day) {
    final date = DateTime(year, m, day);
    final todayOnly = DateTime(today.year, today.month, today.day);
    if (date.isAfter(todayOnly)) return null;
    return statusByDate[_dateKey(year, m, day)] ?? DayStatus.notLogged;
  }

  Color _cellColor(DayStatus? status) => switch (status) {
    null => Colors.grey.shade800,
    DayStatus.notLogged => Colors.black,
    DayStatus.red => Colors.red.shade400,
    DayStatus.yellow => Colors.amber.shade700,
    DayStatus.green => Colors.green.shade700,
  };

  Color _textColor(DayStatus? status) => switch (status) {
    null => Colors.white38,
    DayStatus.notLogged => Colors.white,
    DayStatus.red || DayStatus.yellow || DayStatus.green => Colors.black,
  };

  @override
  Widget build(BuildContext context) {
    final year = month.year;
    final m = month.month;
    final daysInMonth = DateTime(year, m + 1, 0).day;
    // weekday: 1=Mon..7=Sun -> offset 0..6
    final firstWeekday = DateTime(year, m).weekday - 1;
    final totalCells = firstWeekday + daysInMonth;
    final rows = (totalCells / 7).ceil();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.white70),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: onPrevMonth,
              ),
              Text(
                '${_monthNames[m - 1]} $year',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, color: Colors.white70),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: onNextMonth,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: _weekHeaders
                .map(
                  (h) => SizedBox(
                    width: 30,
                    child: Text(
                      h,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 4),
          ...List.generate(rows, (row) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(7, (col) {
                final cell = row * 7 + col;
                final day = cell - firstWeekday + 1;
                if (day < 1 || day > daysInMonth) {
                  return const SizedBox(width: 30, height: 30);
                }
                final status = _statusFor(year, m, day);
                final cellWidget = Container(
                  width: 30,
                  height: 30,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _cellColor(status),
                    border: status == DayStatus.notLogged
                        ? Border.all(color: Colors.white70)
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$day',
                    style: TextStyle(
                      color: _textColor(status),
                      fontSize: 12,
                      fontWeight:
                          status != null && status != DayStatus.notLogged
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                );
                if (onDaySelected == null) return cellWidget;
                return GestureDetector(
                  onTap: () => onDaySelected!(DateTime(year, m, day)),
                  child: cellWidget,
                );
              }),
            );
          }),
        ],
      ),
    );
  }
}
