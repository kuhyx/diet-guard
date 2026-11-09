/// The grouped day/entry list rendered by the history screen.
///
/// Split out of `history_screen.dart` to hold the repo's 250-line cap.
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/services/budget_history_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/ui/cues.dart';
import 'package:diet_guard_app/ui/macro_kind.dart';
import 'package:diet_guard_app/ui/source_icon.dart';
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
              Icon(
                Icons.restaurant,
                size: 14,
                color: colorScheme.onSurfaceVariant,
                semanticLabel: 'entries',
              ),
              const SizedBox(width: 3),
              Text('${header.entryCount}', style: textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(
                MacroKind.kcal.icon,
                size: 14,
                color: kcalColor,
                semanticLabel: 'kcal',
              ),
              const SizedBox(width: 3),
              Text(
                '${header.totalKcal.round()} / $goal',
                style: textTheme.bodySmall?.copyWith(color: kcalColor),
              ),
              const SizedBox(width: 12),
              MacroFigure(
                kind: MacroKind.protein,
                value: '${header.totalProtein.round()}g',
              ),
              const SizedBox(width: 8),
              MacroFigure(
                kind: MacroKind.carbs,
                value: '${header.totalCarbs.round()}g',
              ),
              const SizedBox(width: 8),
              MacroFigure(
                kind: MacroKind.fat,
                value: '${header.totalFat.round()}g',
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
      subtitle: Row(
        children: [
          Flexible(child: Text(entry.time, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          SourceMark(entry.source),
        ],
      ),
      // Delete needs a focusable control, not just a long-press. Long-press has
      // no keyboard equivalent at all, so on the desktop build (a Chrome --app
      // window) deleting an entry was pointer-only: unreachable by keyboard and
      // invisible to a screen reader. The trailing row keeps the kcal figure
      // and adds an IconButton, which Tab reaches and Enter/Space activates.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MacroFigure(
            kind: MacroKind.kcal,
            value: entry.kcal.toStringAsFixed(0),
            size: 14,
          ),
          if (canDelete)
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                semanticLabel: 'Delete entry',
              ),
              onPressed: () => unawaited(_delete(context)),
            ),
        ],
      ),
      // Any entry can be edited (legacy null-id entries gain a UUID on save).
      // Delete remains id-only to avoid ambiguous time+desc matches.
      onTap: () => onEdit?.call(),
      // Retained as a redundant pointer shortcut, never the only route.
      onLongPress: canDelete ? () => unawaited(_delete(context)) : null,
    );
  }

  /// Deletes at once and offers an icon-only undo instead of asking first.
  ///
  /// The snackbar is raised before the awaits because the reload that
  /// follows rebuilds the list and may dispose this tile's context. Undo
  /// writes the live copy back over the tombstone (same id), then reloads.
  Future<void> _delete(BuildContext context) async {
    showCueSnack(
      context,
      kind: CueKind.ok,
      icon: Icons.delete_outline,
      semanticLabel: 'Entry deleted',
      onUndo: () => unawaited(_restore()),
    );
    await LogStorageService.instance.deleteEntry(entry.id!);
    await onDelete?.call();
  }

  Future<void> _restore() async {
    await LogStorageService.instance.updateEntry(
      entry.copyWithDeleted(),
      entry,
    );
    await onDelete?.call();
  }
}

// ---------------------------------------------------------------------------
// Filter sheet
// ---------------------------------------------------------------------------
