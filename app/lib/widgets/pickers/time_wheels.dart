/// The time picker's two looping wheels: hour 00-23 and minute 00-59, 24 h.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:diet_guard_app/widgets/pickers/numeral_wheel.dart';
import 'package:flutter/material.dart';

/// Width of one time wheel.
const double kTimeWheelWidth = 72;

/// Whether hour [h] holds any minute of day in [min]..[max].
bool hourAllowed(int h, int min, int max) =>
    h * 60 + 59 >= min && h * 60 <= max;

/// [minute] of day pulled into [min]..[max].
int clampMinute(int minute, int min, int max) => minute.clamp(min, max);

/// Hour and minute wheels for a minute of day within [minMinute]..[maxMinute].
///
/// Hours and minutes outside the range are dimmed and inert. Changing the
/// hour pulls the minute to the nearest allowed one in that hour, so the
/// value reported is always in range.
class TimeWheels extends StatelessWidget {
  /// Creates a [TimeWheels].
  const TimeWheels({
    required this.minute,
    required this.minMinute,
    required this.maxMinute,
    required this.onChanged,
    super.key,
  });

  /// The current minute of day (in range).
  final int minute;

  /// Earliest allowed minute of day.
  final int minMinute;

  /// Latest allowed minute of day.
  final int maxMinute;

  /// Called with each new in-range minute of day.
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final hour = minute ~/ 60;
    Widget wheel(Widget child) => SizedBox(
      width: kTimeWheelWidth,
      height: kWheelItemExtent * 5,
      child: child,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.xs,
      children: [
        wheel(
          NumeralWheel(
            key: const ValueKey('hour'),
            count: 24,
            value: hour,
            loop: true,
            digits: 2,
            semanticLabel: 'Hour',
            autofocus: true,
            enabled: (h) => hourAllowed(h, minMinute, maxMinute),
            onChanged: (h) => onChanged(
              clampMinute(h * 60 + minute % 60, minMinute, maxMinute),
            ),
          ),
        ),
        const Text(':', style: TextStyle(fontSize: AppTextSize.title)),
        wheel(
          NumeralWheel(
            key: const ValueKey('minute'),
            count: 60,
            value: minute % 60,
            loop: true,
            digits: 2,
            semanticLabel: 'Minute',
            enabled: (m) {
              final v = hour * 60 + m;
              return v >= minMinute && v <= maxMinute;
            },
            onChanged: (m) => onChanged(hour * 60 + m),
          ),
        ),
      ],
    );
  }
}
