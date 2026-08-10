/// The "not syncing" banner for the log screen.
library;

import 'package:diet_guard_app/services/sync_health.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Warns, in place, that meals logged here are not reaching other devices.
///
/// Renders nothing at all unless [SyncHealthStatus.isStalled], so a healthy
/// device never pays for it. This is deliberately on the log screen rather
/// than buried in Settings: the whole failure mode being guarded against is
/// one that stayed invisible while the user kept logging meals that went
/// nowhere.
class SyncHealthBanner extends StatelessWidget {
  /// Creates a [SyncHealthBanner] for [status].
  const SyncHealthBanner({required this.status, super.key});

  /// The health to render, or null before the first read.
  final SyncHealthStatus? status;

  @override
  Widget build(BuildContext context) {
    final message = status?.message;
    if (message == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    // Null-safe lookup, matching slot_selector_row/day_status_calendar: a
    // widget test that pumps a bare MaterialApp has no theme extension, and
    // `!` there is a crash rather than a missing colour.
    final warning =
        (theme.extension<AppStatusColors>() ?? AppStatusColors.dark).warning;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        // A tinted fill plus a border, no shadow: the unified design system
        // allows only one depth technique per surface, and shadows are out
        // entirely in dark UI.
        color: warning.withValues(alpha: 0.12),
        border: Border.all(color: warning.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: warning),
            ),
          ),
        ],
      ),
    );
  }
}
