/// The time dialog: hour and minute wheels between check and close icons.
library;

import 'package:diet_guard_app/widgets/pickers/picker_frame.dart';
import 'package:diet_guard_app/widgets/pickers/time_wheels.dart';
import 'package:flutter/material.dart';

/// Pops the chosen [TimeOfDay], always within [minMinute]..[maxMinute].
class TimeDialog extends StatefulWidget {
  /// Creates a [TimeDialog]; [initialMinute] is clamped into range, since a
  /// value written by another device may lie outside it.
  const TimeDialog({
    required this.initialMinute,
    required this.minMinute,
    required this.maxMinute,
    super.key,
  });

  /// The starting minute of day.
  final int initialMinute;

  /// Earliest allowed minute of day.
  final int minMinute;

  /// Latest allowed minute of day.
  final int maxMinute;

  @override
  State<TimeDialog> createState() => _TimeDialogState();
}

class _TimeDialogState extends State<TimeDialog> {
  late int _minute = clampMinute(
    widget.initialMinute,
    widget.minMinute,
    widget.maxMinute,
  );

  @override
  Widget build(BuildContext context) => PickerFrame(
    canConfirm: true,
    onConfirm: () => Navigator.of(
      context,
    ).pop(TimeOfDay(hour: _minute ~/ 60, minute: _minute % 60)),
    child: TimeWheels(
      minute: _minute,
      minMinute: widget.minMinute,
      maxMinute: widget.maxMinute,
      onChanged: (m) => setState(() => _minute = m),
    ),
  );
}
