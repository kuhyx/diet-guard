/// The Body screen's overview: two-column metric tiles that fit one phone
/// screen. Tapping a tile opens the section's full card in a bottom sheet.
library;

import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// One tile: a section [title], an optional headline [value], and the
/// [builder] of the full card shown in the sheet.
class BodyTileSpec {
  /// Creates a tile spec.
  const BodyTileSpec({required this.title, required this.builder, this.value});

  /// Section name, the same text the full card carries.
  final String title;

  /// Headline number for the tile (null when the section has none).
  final String? value;

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
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                spec.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              if (spec.value != null)
                Text(
                  spec.value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
