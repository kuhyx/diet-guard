/// Shape + colour vocabulary for the nutrition fields, so a field or figure
/// is recognised by its glyph instead of a "P"/"C"/"F"/"kcal" word.
///
/// Protein is a green circle, carbs an amber triangle, fat a blue square;
/// colour never carries the meaning alone (shape does too).
library;

import 'package:flutter/material.dart';

/// One nutrition field and its non-text identity.
enum MacroKind {
  /// Reference weight the typed macros are stated for.
  perGrams(Icons.scale, Color(0xFFAAA09A), 'per (g)', 'per'),

  /// Energy.
  kcal(Icons.bolt, Color(0xFFE08A3C), 'kcal', 'kcal'),

  /// Protein.
  protein(Icons.circle, Color(0xFF8A9A3C), 'protein g', 'P'),

  /// Carbohydrate.
  carbs(Icons.change_history, Color(0xFFE0A63C), 'carbs g', 'C'),

  /// Fat.
  fat(Icons.square, Color(0xFF6C9BD1), 'fat g', 'F'),

  /// Portion weight actually eaten.
  eaten(Icons.rice_bowl, Color(0xFFAAA09A), 'eaten (g)', 'eaten');

  const MacroKind(this.icon, this.color, this._long, this._short);

  /// Painted glyph.
  final IconData icon;

  /// Glyph tint.
  final Color color;

  final String _long;
  final String _short;

  /// Spoken name; the long form unless [compact].
  String semanticLabel({required bool compact}) => compact ? _short : _long;
}

/// A glyph + number pair, e.g. a green circle and `12`.
class MacroFigure extends StatelessWidget {
  /// Creates a figure for [kind] showing [grams] (or [value] verbatim).
  const MacroFigure({
    required this.kind,
    required this.value,
    this.size = 12,
    super.key,
  });

  /// Which nutrient.
  final MacroKind kind;

  /// The number to show, already formatted.
  final String value;

  /// Glyph size.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          kind.icon,
          color: kind.color,
          size: size,
          semanticLabel: kind.semanticLabel(compact: false),
        ),
        const SizedBox(width: 3),
        Text(value),
      ],
    );
  }
}
