/// One tappable numeral of the pickers' grids (a day, a month), plus the
/// equal-width row layout both grids use.
library;

import 'package:flutter/material.dart';

/// Alpha of a weekend numeral: dimmed, with a dot as the second channel.
const double kWeekendAlpha = 0.6;

/// Alpha of an out-of-range numeral: far below [kWeekendAlpha], so an
/// out-of-range weekend never reads like an in-range one.
const double kDisabledAlpha = 0.25;

/// Alpha of the shaded band between two range ends.
const double kBandAlpha = 0.3;

/// A numeral in a stadium. Every visual state is a field, so tests assert
/// state rather than colours.
class NumeralCell extends StatelessWidget {
  /// Creates a [NumeralCell].
  const NumeralCell({
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.enabled = true,
    this.selected = false,
    this.band = false,
    this.ring = false,
    this.dot = false,
    this.focused = false,
    super.key,
  });

  /// The painted numeral.
  final String label;

  /// The spoken name (a full date, a month); never painted.
  final String semanticLabel;

  /// Called on tap when [enabled].
  final VoidCallback onTap;

  /// Out-of-range cells are dimmed and inert.
  final bool enabled;

  /// Filled: the chosen value (a range end is a filled cap).
  final bool selected;

  /// Shaded background: inside a chosen range.
  final bool band;

  /// Outlined: today.
  final bool ring;

  /// Dimmed with a dot below: a weekend.
  final bool dot;

  /// The keyboard cursor.
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final alpha = !enabled ? kDisabledAlpha : (dot ? kWeekendAlpha : 1.0);
    final fg = selected
        ? scheme.onPrimary
        : scheme.onSurface.withValues(alpha: alpha);
    final edge = ring || focused
        ? BorderSide(color: focused ? scheme.outline : scheme.primary, width: 2)
        : BorderSide.none;
    final shape = StadiumBorder(side: edge);
    return Semantics(
      label: semanticLabel,
      button: true,
      selected: selected,
      enabled: enabled,
      // excludeSemantics drops the InkWell's own tap action, so the node
      // offers it here or a screen reader cannot pick a day.
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: ColoredBox(
        // Translucent, not primaryContainer: in this theme that equals
        // primary, which hid the filled range ends inside the band.
        color: band
            ? scheme.primary.withValues(alpha: kBandAlpha)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: shape,
              canRequestFocus: false,
              onTap: enabled ? onTap : null,
              child: Ink(
                decoration: ShapeDecoration(
                  shape: shape,
                  color: selected ? scheme.primary : null,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: fg,
                          fontWeight: selected ? FontWeight.bold : null,
                        ),
                      ),
                      if (dot)
                        Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            color: fg,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays [cells] out in rows of [columns] equal-width cells, each
/// [aspectRatio] wide per unit of height; a short last row is padded.
Widget numeralRows(int columns, List<Widget> cells, {double aspectRatio = 1}) =>
    Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < cells.length; r += columns)
          Row(
            children: [
              for (var c = r; c < r + columns; c++)
                Expanded(
                  child: AspectRatio(
                    aspectRatio: aspectRatio,
                    child: c < cells.length
                        ? cells[c]
                        : const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
      ],
    );
