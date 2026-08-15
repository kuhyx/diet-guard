/// The grouped day/entry list rendered by the history screen.
///
/// Split out of `history_screen.dart` to hold the repo's 250-line cap.
library;

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/history/history_grouping.dart';
import 'package:flutter/material.dart';

/// The history list: a flat [ListView] over pre-grouped day headers and rows.
///
/// Grouping happens in [buildGroupedItems] rather than here, so the list stays
/// a dumb renderer of whatever [HistoryItem] sequence it is handed.
class GroupedList extends StatelessWidget {
  /// Creates a [GroupedList] over already-grouped [items].
  const GroupedList({
    required this.items,
    required this.onDeleteEntry,
    required this.onEditEntry,
    super.key,
  });

  /// Day headers and entry rows, in display order.
  final List<HistoryItem> items;

  /// Called after a confirmed delete so the parent can reload.
  final Future<void> Function() onDeleteEntry;

  /// Called with the entry to edit when a row is tapped.
  final Future<void> Function(FoodEntry) onEditEntry;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return switch (item) {
          DayHeader() => DayHeaderTile(item),
          EntryRow() => EntryTile(
            item.entry,
            onDelete: onDeleteEntry,
            onEdit: () => onEditEntry(item.entry),
          ),
        };
      },
    );
  }
}

/// The sticky-looking header that starts each day's group of entries.
class DayHeaderTile extends StatelessWidget {
  /// Creates a [DayHeaderTile] for [header].
  const DayHeaderTile(this.header, {super.key});

  /// The day this header summarises (date key, totals, budget for that day).
  final DayHeader header;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // The budget that applied on *that* day, not today's -- a later budget
    // change must not repaint months of history red.
    final goal = BudgetHistoryService.schedule.forDay(header.dateKey);
    final kcalColor = header.totalKcal > goal
        ? colorScheme.error
        : colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  formatDay(header.dateKey),
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '${header.entryCount}'
                ' ${header.entryCount == 1 ? 'entry' : 'entries'}',
                style: textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                '${header.totalKcal.round()} / $goal kcal',
                style: textTheme.bodySmall?.copyWith(color: kcalColor),
              ),
              const SizedBox(width: 8),
              Text(
                'P ${header.totalProtein.round()}g · '
                'C ${header.totalCarbs.round()}g · '
                'F ${header.totalFat.round()}g',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One logged meal: description, macros, and swipe/tap actions.
class EntryTile extends StatelessWidget {
  /// Creates an [EntryTile] for [entry].
  const EntryTile(this.entry, {super.key, this.onDelete, this.onEdit});

  /// The entry this tile renders.
  final FoodEntry entry;

  /// Called after a confirmed delete so the parent can reload.
  final Future<void> Function()? onDelete;

  /// Called when the tile is tapped to open the edit screen.
  final Future<void> Function()? onEdit;

  @override
  Widget build(BuildContext context) {
    final canDelete = entry.id != null;
    return ListTile(
      leading: const Icon(Icons.restaurant),
      title: Text(entry.desc),
      subtitle: Text('${entry.time}  •  ${entry.source}'),
      // Delete needs a focusable control, not just a long-press. Long-press has
      // no keyboard equivalent at all, so on the desktop build (a Chrome --app
      // window) deleting an entry was pointer-only: unreachable by keyboard and
      // invisible to a screen reader. The trailing row keeps the kcal figure
      // and adds an IconButton, which Tab reaches and Enter/Space activates.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${entry.kcal.toStringAsFixed(0)} kcal'),
          if (canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete entry',
              onPressed: () => _confirmDelete(context),
            ),
        ],
      ),
      // Any entry can be edited (legacy null-id entries gain a UUID on save).
      // Delete remains id-only to avoid ambiguous time+desc matches.
      onTap: () => onEdit?.call(),
      // Retained as a redundant pointer shortcut, never the only route.
      onLongPress: canDelete ? () => _confirmDelete(context) : null,
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text('Remove "${entry.desc}" from history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await LogStorageService.instance.deleteEntry(entry.id!);
      await onDelete?.call();
    }
  }
}

// ---------------------------------------------------------------------------
// Filter sheet
// ---------------------------------------------------------------------------
