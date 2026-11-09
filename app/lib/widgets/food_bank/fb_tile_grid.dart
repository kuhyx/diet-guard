/// Paged 3-column tile grid for the food bank: a whole page of foods fits one
/// phone screen with no vertical scrolling, and further pages are a horizontal
/// swipe away. Tapping a tile opens the full macro line in a sheet.
library;

import 'package:diet_guard_app/models/food_bank_record.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:diet_guard_app/ui/theme.dart';
import 'package:flutter/material.dart';

/// Tiles per row.
const int fbGridColumns = 3;

/// Fixed tile height (dp); the page's row count is derived from it.
const double fbTileHeight = 76;

/// Bottom strip kept clear for the page dots and the floating add button.
const double fbBottomReserve = 72;

/// How many rows of [fbTileHeight] fit in [height] after the reserve.
int fbRowsFor(double height) {
  final usable = height - fbBottomReserve + AppSpacing.sm;
  final rows = (usable / (fbTileHeight + AppSpacing.sm)).floor();
  return rows < 1 ? 1 : rows;
}

/// One banked food as a tile: its name, kcal and use count.
class FbTile extends StatelessWidget {
  /// Creates a tile for [record].
  const FbTile(this.record, {required this.onTap, super.key});

  /// The banked food.
  final FoodBankRecord record;

  /// Opens the detail sheet.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        onLongPress: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  record.desc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: MacroFigure(
                        kind: MacroKind.kcal,
                        value: record.kcal.toStringAsFixed(0),
                        size: 14,
                      ),
                    ),
                  ),
                  if (record.count > 0)
                    Text(
                      '×${record.count.toStringAsFixed(0)}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Swipeable pages of [FbTile]s sized to the space the parent gives it.
class FbTileGrid extends StatefulWidget {
  /// Creates the grid; [onOpen] receives the tapped record.
  const FbTileGrid({required this.records, required this.onOpen, super.key});

  /// Everything to page through, in display order.
  final List<FoodBankRecord> records;

  /// Called when a tile is tapped.
  final ValueChanged<FoodBankRecord> onOpen;

  @override
  State<FbTileGrid> createState() => _FbTileGridState();
}

class _FbTileGridState extends State<FbTileGrid> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _row(List<FoodBankRecord> cells) {
    return SizedBox(
      height: fbTileHeight,
      child: Row(
        children: [
          for (var c = 0; c < fbGridColumns; c++) ...[
            if (c > 0) const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: c < cells.length
                  ? FbTile(cells[c], onTap: () => widget.onOpen(cells[c]))
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pageOf(List<FoodBankRecord> page) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Column(
        children: [
          for (var i = 0; i < page.length; i += fbGridColumns) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            _row(page.sublist(i, (i + fbGridColumns).clamp(0, page.length))),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final perPage = fbRowsFor(box.maxHeight) * fbGridColumns;
        final total = widget.records.length;
        final pages = (total / perPage).ceil();
        final current = _page.clamp(0, pages - 1);
        return Column(
          children: [
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: pages,
                onPageChanged: (p) => setState(() => _page = p),
                itemBuilder: (context, p) => Align(
                  alignment: Alignment.topCenter,
                  child: _pageOf(
                    widget.records.sublist(
                      p * perPage,
                      ((p + 1) * perPage).clamp(0, total),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: fbBottomReserve - AppSpacing.sm,
              child: Center(
                child: _Dots(count: pages, current: current),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    if (count < 2) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // Long banks would overflow a row of dots: show a sliding window of 7.
    final start = (current - 3).clamp(0, (count - 7).clamp(0, count));
    final end = (start + 7).clamp(0, count);
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = start; i < end; i++)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == current
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.25),
              ),
            ),
        ],
      ),
    );
  }
}
