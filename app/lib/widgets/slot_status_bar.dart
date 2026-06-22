/// Shows today's 08:00/12:00/16:00/20:00 slot status.
library;

import 'package:diet_guard_app/models/slot.dart';
import 'package:flutter/material.dart';

/// Renders each of today's meal slots as logged / due / upcoming.
class SlotStatusBar extends StatelessWidget {
  /// Creates a [SlotStatusBar] for [now] given [loggedSlots] satisfied so
  /// far today.
  const SlotStatusBar({
    required this.now,
    required this.loggedSlots,
    super.key,
  });

  /// Reference time used to decide which slots have elapsed.
  final DateTime now;

  /// Slot hours already satisfied by today's log.
  final Set<int> loggedSlots;

  @override
  Widget build(BuildContext context) {
    final elapsed = elapsedSlots(now).toSet();
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: daySlots().map((slot) {
        final label = slotLabel(slot);
        final String status;
        final Color color;
        if (loggedSlots.contains(slot)) {
          status = 'logged';
          color = Colors.green;
        } else if (elapsed.contains(slot)) {
          status = 'DUE';
          color = Colors.red;
        } else {
          status = 'upcoming';
          color = Colors.grey;
        }
        return Chip(
          label: Text('$label $status'),
          backgroundColor: color.withValues(alpha: 0.15),
          labelStyle: TextStyle(color: color),
        );
      }).toList(),
    );
  }
}
