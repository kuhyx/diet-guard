/// The month row of the date picker: numerals 1-12 instead of month names.
library;

import 'package:diet_guard_app/widgets/pickers/numeral_cell.dart';
import 'package:flutter/material.dart';

/// Twelve numeral chips in two rows of six; months wholly outside the bounds
/// are dimmed and inert.
class MonthChips extends StatelessWidget {
  /// Creates a [MonthChips].
  const MonthChips({
    required this.year,
    required this.selected,
    required this.allowed,
    required this.onTap,
    super.key,
  });

  /// The shown year (for the spoken month names).
  final int year;

  /// The shown month, 1-12.
  final int selected;

  /// Whether month 1-12 has any day within the bounds.
  final bool Function(int month) allowed;

  /// Called with a tapped allowed month.
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    return numeralRows(6, aspectRatio: 1.6, [
      for (var m = 1; m <= 12; m++)
        NumeralCell(
          key: ValueKey('month-$m'),
          label: '$m',
          semanticLabel: l10n.formatMonthYear(DateTime(year, m)),
          onTap: () => onTap(m),
          enabled: allowed(m),
          selected: m == selected,
        ),
    ]);
  }
}
