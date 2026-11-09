/// The log form's "Fill all with catering" row: one button, plus Cancel while
/// a proposal is armed.
///
/// Its own row rather than a third control in [LogMealActionsRow]: that row is
/// already full on a narrow phone, and "✓ Confirm (N)" must stay legible.
library;

import 'package:diet_guard_app/services/kuchnia_client.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Spoken name of the resting button (never painted).
const fillAllLabel = 'Fill all with catering';

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
            child: _face(context, armed),
          ),
        ),
        if (armed) ...[
          const SizedBox(width: AppSpacing.sm),
          IconButton(
            onPressed: busy ? null : onCancel,
            icon: const Icon(Icons.close, semanticLabel: 'Cancel'),
          ),
        ],
      ],
    );
  }

  /// Resting glyph; spinner while busy; double check + count once armed.
  Widget _face(BuildContext context, bool armed) {
    if (busy) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (!armed) {
      return const Icon(Icons.playlist_add_check, semanticLabel: fillAllLabel);
    }
    final success =
        (Theme.of(context).extension<AppStatusColors>() ?? AppStatusColors.dark)
            .success;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.done_all, color: success, semanticLabel: 'Confirm'),
        const SizedBox(width: AppSpacing.xs),
        Text('$armedCount'),
      ],
    );
  }
}
