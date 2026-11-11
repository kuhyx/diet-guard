/// Icon-only replacements for `showDatePicker`, `showDateRangePicker` and
/// `showTimePicker`, which paint "Select date", "Cancel", "OK" and tooltips.
///
/// Same arguments as the framework calls, so a call site changes by one
/// function name. Dropped on purpose: the weekday header, month names and
/// both text-entry modes (see the textgate rework report).
library;

import 'package:diet_guard_app/widgets/pickers/date_dialog.dart';
import 'package:diet_guard_app/widgets/pickers/date_selection.dart';
import 'package:diet_guard_app/widgets/pickers/time_dialog.dart';
import 'package:flutter/material.dart';

/// Picks one day in [firstDate]..[lastDate]; null when cancelled.
///
/// [initialDatePickerMode] `year` focuses the year wheel first.
Future<DateTime?> pickDate({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTime? initialDate,
  DatePickerMode initialDatePickerMode = DatePickerMode.day,
}) => showDialog<DateTime>(
  context: context,
  builder: (_) => DateDialog(
    selection: DateSelection.single(
      first: firstDate,
      last: lastDate,
      initial: initialDate,
    ),
    startOnYear: initialDatePickerMode == DatePickerMode.year,
  ),
);

/// Picks a range of days in [firstDate]..[lastDate] by two taps; null when
/// cancelled.
Future<DateTimeRange?> pickDateRange({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  DateTimeRange? initialDateRange,
}) => showDialog<DateTimeRange>(
  context: context,
  builder: (_) => DateDialog(
    selection: DateSelection.range(
      first: firstDate,
      last: lastDate,
      initial: initialDateRange,
    ),
  ),
);

/// Picks a 24 h time whose minute of day lies in [minMinute]..[maxMinute];
/// null when cancelled.
Future<TimeOfDay?> pickTime({
  required BuildContext context,
  required TimeOfDay initialTime,
  int minMinute = 0,
  int maxMinute = 24 * 60 - 1,
}) => showDialog<TimeOfDay>(
  context: context,
  builder: (_) => TimeDialog(
    initialMinute: initialTime.hour * 60 + initialTime.minute,
    minMinute: minMinute,
    maxMinute: maxMinute,
  ),
);
