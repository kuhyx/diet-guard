/// The date and date-range dialog: month chips above, the day grid with the
/// year wheel beside it, check and close icons below.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/pickers/date_grid.dart';
import 'package:diet_guard_app/widgets/pickers/date_selection.dart';
import 'package:diet_guard_app/widgets/pickers/month_chips.dart';
import 'package:diet_guard_app/widgets/pickers/picker_frame.dart';
import 'package:diet_guard_app/widgets/pickers/year_wheel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Width of the year wheel beside the grid.
const double kYearWheelWidth = 64;

/// Pops a `DateTime` (single mode) or a `DateTimeRange` (range mode).
///
/// Keyboard: arrows move the grid cursor by a day or a week, Space taps the
/// cursor day in range mode, Enter confirms, Esc cancels.
class DateDialog extends StatefulWidget {
  /// Creates a [DateDialog] over [selection].
  const DateDialog({
    required this.selection,
    this.startOnYear = false,
    this.today,
    super.key,
  });

  /// The selection to edit; its mode decides the popped type.
  final DateSelection selection;

  /// Focus the year wheel first (the birth-date flow) instead of the grid.
  final bool startOnYear;

  /// The day to ring; now when null (a seam for tests).
  final DateTime? today;

  @override
  State<DateDialog> createState() => _DateDialogState();
}

class _DateDialogState extends State<DateDialog> {
  DateSelection get _sel => widget.selection;
  bool _gridFocused = false;

  void _confirm() => Navigator.of(
    context,
  ).pop<Object>(_sel.range ? _sel.dateRange : _sel.start);

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      LogicalKeyboardKey.arrowUp => -7,
      LogicalKeyboardKey.arrowDown => 7,
      _ => 0,
    };
    if (step != 0) {
      setState(() => _sel.moveCursor(step));
      return KeyEventResult.handled;
    }
    if (_sel.range && event.logicalKey == LogicalKeyboardKey.space) {
      setState(() => _sel.tap(_sel.cursor));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => PickerFrame(
    canConfirm: _sel.canConfirm,
    onConfirm: _confirm,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MonthChips(
          year: _sel.year,
          selected: _sel.month,
          allowed: (m) => _sel.monthAllowed(_sel.year, m),
          onTap: (m) => setState(() => _sel.showMonth(m)),
        ),
        const SizedBox(height: AppSpacing.sm),
        LayoutBuilder(
          builder: (context, constraints) {
            final gridWidth =
                constraints.maxWidth - kYearWheelWidth - AppSpacing.sm;
            return SizedBox(
              height: gridWidth / 7 * (kGridCells ~/ 7),
              child: Row(
                spacing: AppSpacing.sm,
                children: [
                  Expanded(
                    child: Focus(
                      autofocus: !widget.startOnYear,
                      onKeyEvent: _key,
                      onFocusChange: (f) => setState(() => _gridFocused = f),
                      child: DateGrid(
                        selection: _sel,
                        today: widget.today ?? DateTime.now(),
                        showCursor: _gridFocused,
                        onTap: (day) => setState(() => _sel.tap(day)),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: kYearWheelWidth,
                    child: YearWheel(
                      firstYear: _sel.first.year,
                      lastYear: _sel.last.year,
                      value: _sel.year,
                      autofocus: widget.startOnYear,
                      onChanged: (y) => setState(() => _sel.showYear(y)),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    ),
  );
}
