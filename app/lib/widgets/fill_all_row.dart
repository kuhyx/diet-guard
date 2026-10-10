/// The log form's "Fill all with catering" row: one button, plus Cancel while
/// a proposal is armed.
///
/// Its own row rather than a third control in [LogMealActionsRow]: that row is
/// already full on a narrow phone, and "✓ Confirm (N)" must stay legible.
library;

import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Resting label, mirroring the PC gate's "🍱 Fill all".
const fillAllLabel = '🍱 Fill all with catering';

/// Fill-all button; relabels to "✓ Confirm (N)" once a proposal is armed.
class FillAllRow extends StatelessWidget {
  /// Creates the row.
  const FillAllRow({
    required this.onFill,
    required this.onCancel,
    this.busy = false,
    this.armedCount = 0,
    this.canFetchDelivery,
    super.key,
  });

  /// First tap proposes, second tap confirms.
  final Future<void> Function() onFill;

  /// Disarms a proposal without writing anything.
  final VoidCallback onCancel;

  /// Disables both controls while a fetch or the confirm's writes run.
  final bool busy;

  /// How many dishes the armed proposal would log; 0 when none is armed.
  final int armedCount;

  /// Whether the platform can fetch at all. Defaults to
  /// [kuchniaFetchSupported] -- false on web, where the caterer's panel blocks
  /// browser requests -- so the row is hidden there, like the delivery button.
  final bool? canFetchDelivery;

  @override
  Widget build(BuildContext context) {
    if (!(canFetchDelivery ?? kuchniaFetchSupported)) {
      return const SizedBox.shrink();
    }
    final armed = armedCount > 0;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: busy ? null : onFill,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(_label(armed), maxLines: 1),
            ),
          ),
        ),
        if (armed) ...[
          const SizedBox(width: AppSpacing.sm),
          TextButton(
            onPressed: busy ? null : onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }

  String _label(bool armed) {
    if (busy) return 'Working…';
    if (armed) return '✓ Confirm ($armedCount)';
    return fillAllLabel;
  }
}
