/// The date picker's year wheel: numerals, no loop.
library;

import 'package:diet_guard_app/widgets/pickers/numeral_wheel.dart';
import 'package:flutter/material.dart';

/// Out-of-range years listed beyond each bound, dimmed and inert, so the
/// wheel's ends read as limits rather than as a list that just stops.
const int kYearWheelPad = 2;

/// A non-looping wheel of the years [firstYear]..[lastYear], plus
/// [kYearWheelPad] dimmed, inert years past each end (a wheel dragged onto
/// one springs back).
class YearWheel extends StatelessWidget {
  /// Creates a [YearWheel].
  const YearWheel({
    required this.firstYear,
    required this.lastYear,
    required this.value,
    required this.onChanged,
    this.autofocus = false,
    super.key,
  });

  /// Earliest listed year.
  final int firstYear;

  /// Latest listed year.
  final int lastYear;

  /// The shown year.
  final int value;

  /// Called with a newly centred year.
  final ValueChanged<int> onChanged;

  /// Whether the wheel takes keyboard focus on open (the birth-date flow).
  final bool autofocus;

  @override
  Widget build(BuildContext context) => NumeralWheel(
    count: lastYear - firstYear + 1 + 2 * kYearWheelPad,
    offset: firstYear - kYearWheelPad,
    enabled: (y) => y >= firstYear && y <= lastYear,
    value: value,
    onChanged: onChanged,
    semanticLabel: 'Year',
    autofocus: autofocus,
  );
}
