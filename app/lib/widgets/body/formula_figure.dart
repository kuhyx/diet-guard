/// A kcal formula shown as a glyph + number; its proper name is only the
/// glyph's spoken label.
library;

import 'package:diet_guard_app/services/activity_kcal.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// One distinct glyph per entry of [activityFormulas].
const Map<String, IconData> formulaIcons = {
  'MET': Icons.speed,
  'ACSM': Icons.functions,
  'Per-km': Icons.straighten,
};

/// The glyph for formula [name], spoken as the formula's proper name.
class FormulaGlyph extends StatelessWidget {
  /// Creates a glyph for [name].
  const FormulaGlyph(this.name, {this.size = 16, super.key});

  /// The formula's proper name (a key of [formulaIcons]).
  final String name;

  /// Glyph size.
  final double size;

  // The proper name is spoken only: a tooltip paints on long-press.
  @override
  Widget build(BuildContext context) => Icon(
    formulaIcons[name],
    size: size,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    semanticLabel: name,
  );
}

/// Glyph + number (a trailing `~` marks a figure that reuses the MET value).
class FormulaFigure extends StatelessWidget {
  /// Creates a figure.
  const FormulaFigure(
    this.name,
    this.value, {
    this.fallback = false,
    super.key,
  });

  /// The formula's proper name.
  final String name;

  /// The formatted kcal number.
  final String value;

  /// Whether the figure is a fallback to the MET value.
  final bool fallback;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      FormulaGlyph(name),
      const SizedBox(width: AppSpacing.xs),
      Text(fallback ? '$value~' : value),
    ],
  );
}
