/// Glyph for where a log entry came from, replacing the stored source word
/// (`manual`, `food bank`, `catering`) that used to be printed on screen.
library;

import 'package:flutter/material.dart';

/// Icon for a stored entry `source` value; unknown values get a neutral dot.
IconData sourceIcon(String source) => switch (source) {
  'manual' => Icons.edit,
  'food bank' => Icons.restaurant_menu,
  'catering' => Icons.local_shipping,
  _ => Icons.circle_outlined,
};

/// A small painted [sourceIcon] that still speaks the stored source value.
class SourceMark extends StatelessWidget {
  /// Creates a mark for [source].
  const SourceMark(this.source, {this.size = 14, super.key});

  /// Stored source value.
  final String source;

  /// Glyph size.
  final double size;

  @override
  Widget build(BuildContext context) => Icon(
    sourceIcon(source),
    size: size,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    semanticLabel: source,
  );
}
