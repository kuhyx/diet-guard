/// The Body screen's overview: two-column icon tiles that fit one phone
/// screen. Tapping a tile opens the section's full card in a bottom sheet.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// One tile: a big [icon] (spoken as [semanticLabel]), an optional headline
/// [value] and the [builder] of the full card shown in the sheet.
class BodyTileSpec {
  /// Creates a tile spec.
  const BodyTileSpec({
    required this.semanticLabel,
    required this.icon,
    required this.builder,
    this.value,
    this.valueIcon,
  });

  /// Spoken name of the section; never painted.
  final String semanticLabel;

  /// The section's glyph.
  final IconData icon;

  /// Headline number for the tile (null when the section has none).
  final String? value;

  /// Small glyph in front of [value] (e.g. a bolt for kcal).
  final IconData? valueIcon;

  /// Builds the full card for the sheet.
  final WidgetBuilder builder;
}

/// Height of one tile row (dp).
const double bodyTileHeight = 84;

/// Lays [tiles] out two per row, in order.
class BodyTileGrid extends StatelessWidget {
  /// Creates the grid.
  const BodyTileGrid({required this.tiles, super.key});

  /// Tiles in display order.
  final List<BodyTileSpec> tiles;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < tiles.length; i += 2) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: bodyTileHeight,
            child: Row(
              children: [
                Expanded(child: _Tile(tiles[i])),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: i + 1 < tiles.length
                      ? _Tile(tiles[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.spec);

  final BodyTileSpec spec;

  Future<void> _open(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: spec.builder(sheet),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = spec.value;
    final valueIcon = spec.valueIcon;
    return Card(
      margin: EdgeInsets.zero,
      child: Semantics(
        button: true,
        label: spec.semanticLabel,
        child: InkWell(
          onTap: () => _open(context),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Icon(
                    spec.icon,
                    size: 36,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (valueIcon != null)
                  Icon(valueIcon, size: 18, color: theme.colorScheme.primary),
                if (value != null)
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
