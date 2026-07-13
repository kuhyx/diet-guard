/// Logged meal history with day grouping, filtering, and sorting.
library;

import 'dart:async';
import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/edit_entry_screen.dart';
import 'package:diet_guard_app/screens/photo_viewer_screen.dart';
import 'package:diet_guard_app/services/app_settings_service.dart';
import 'package:diet_guard_app/services/day_status_service.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Filter & sort state
// ---------------------------------------------------------------------------

/// Sort field for the history list.
enum HistorySortField {
  /// Sort by entry date/time.
  date,

  /// Sort by calories.
  kcal,

  /// Sort by protein (g).
  protein,

  /// Sort by carbohydrates (g).
  carbs,

  /// Sort by fat (g).
  fat,

  /// Sort by description text.
  description,
}

/// All active filter criteria; [isActive] is true when any criterion is set.
class HistoryFilter {
  /// Creates a [HistoryFilter] with the given criteria.
  HistoryFilter({
    this.nameQuery = '',
    this.dateRange,
    this.minKcal,
    this.maxKcal,
    this.minProtein,
    this.maxProtein,
    this.minCarbs,
    this.maxCarbs,
    this.minFat,
    this.maxFat,
    this.hasPhoto,
    this.source,
  });

  /// Substring match on the food description.
  String nameQuery;

  /// Optional date range filter.
  DateTimeRange? dateRange;

  /// Minimum kcal.
  double? minKcal;

  /// Maximum kcal.
  double? maxKcal;

  /// Minimum protein (g).
  double? minProtein;

  /// Maximum protein (g).
  double? maxProtein;

  /// Minimum carbs (g).
  double? minCarbs;

  /// Maximum carbs (g).
  double? maxCarbs;

  /// Minimum fat (g).
  double? minFat;

  /// Maximum fat (g).
  double? maxFat;

  /// null = all, true = with photo, false = without.
  bool? hasPhoto;

  /// null = all, or a source string from the log.
  String? source;

  /// True when any filter criterion is active.
  bool get isActive =>
      nameQuery.isNotEmpty ||
      dateRange != null ||
      minKcal != null ||
      maxKcal != null ||
      minProtein != null ||
      maxProtein != null ||
      minCarbs != null ||
      maxCarbs != null ||
      minFat != null ||
      maxFat != null ||
      hasPhoto != null ||
      source != null;
}

// ---------------------------------------------------------------------------
// List item sealed hierarchy for day-grouped rendering
// ---------------------------------------------------------------------------

sealed class _HistoryItem {}

final class _DayHeader extends _HistoryItem {
  _DayHeader(
    this.dateKey,
    this.totalKcal,
    this.entryCount,
    this.totalProtein,
    this.totalCarbs,
    this.totalFat,
  );
  final String dateKey;
  final double totalKcal;
  final int entryCount;
  final double totalProtein;
  final double totalCarbs;
  final double totalFat;
}

final class _EntryRow extends _HistoryItem {
  _EntryRow(this.entry);
  final FoodEntry entry;
}

// ---------------------------------------------------------------------------
// Pure filter / sort / group helpers
// ---------------------------------------------------------------------------

/// Applies [filter] and sort criteria to [entries] and returns the result.
///
/// Exposed as a top-level function for unit tests.
List<FoodEntry> applyHistoryFilter(
  List<FoodEntry> entries,
  HistoryFilter filter,
  HistorySortField sortField, {
  required bool ascending,
}) {
  var result = [...entries];

  if (filter.nameQuery.isNotEmpty) {
    final q = filter.nameQuery.toLowerCase();
    result = result.where((e) => e.desc.toLowerCase().contains(q)).toList();
  }
  if (filter.dateRange != null) {
    final start = filter.dateRange!.start;
    final end = filter.dateRange!.end.add(const Duration(days: 1));
    result = result.where((e) {
      final t = DateTime.tryParse(e.time);
      return t != null && !t.isBefore(start) && t.isBefore(end);
    }).toList();
  }
  if (filter.minKcal != null) {
    result = result.where((e) => e.kcal >= filter.minKcal!).toList();
  }
  if (filter.maxKcal != null) {
    result = result.where((e) => e.kcal <= filter.maxKcal!).toList();
  }
  if (filter.minProtein != null) {
    result = result.where((e) => e.proteinG >= filter.minProtein!).toList();
  }
  if (filter.maxProtein != null) {
    result = result.where((e) => e.proteinG <= filter.maxProtein!).toList();
  }
  if (filter.minCarbs != null) {
    result = result.where((e) => e.carbsG >= filter.minCarbs!).toList();
  }
  if (filter.maxCarbs != null) {
    result = result.where((e) => e.carbsG <= filter.maxCarbs!).toList();
  }
  if (filter.minFat != null) {
    result = result.where((e) => e.fatG >= filter.minFat!).toList();
  }
  if (filter.maxFat != null) {
    result = result.where((e) => e.fatG <= filter.maxFat!).toList();
  }
  if (filter.hasPhoto != null) {
    result = result
        .where(
          (e) => filter.hasPhoto! ? e.imagePath != null : e.imagePath == null,
        )
        .toList();
  }
  if (filter.source != null) {
    result = result.where((e) => e.source == filter.source).toList();
  }

  result.sort((a, b) {
    int cmp;
    switch (sortField) {
      case HistorySortField.date:
        final at = DateTime.tryParse(a.time) ?? DateTime(0);
        final bt = DateTime.tryParse(b.time) ?? DateTime(0);
        cmp = at.compareTo(bt);
      case HistorySortField.kcal:
        cmp = a.kcal.compareTo(b.kcal);
      case HistorySortField.protein:
        cmp = a.proteinG.compareTo(b.proteinG);
      case HistorySortField.carbs:
        cmp = a.carbsG.compareTo(b.carbsG);
      case HistorySortField.fat:
        cmp = a.fatG.compareTo(b.fatG);
      case HistorySortField.description:
        cmp = a.desc.compareTo(b.desc);
    }
    return ascending ? cmp : -cmp;
  });

  return result;
}

List<_HistoryItem> _buildGroupedItems(List<FoodEntry> entries) {
  final byDay = <String, List<FoodEntry>>{};
  for (final e in entries) {
    final day = e.time.length >= 10 ? e.time.substring(0, 10) : 'unknown';
    byDay.putIfAbsent(day, () => []).add(e);
  }
  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  final items = <_HistoryItem>[];
  for (final day in days) {
    final dayEntries = byDay[day]!;
    final totalKcal = sumKcal(dayEntries);
    final totalProtein = dayEntries.fold<double>(0, (s, e) => s + e.proteinG);
    final totalCarbs = dayEntries.fold<double>(0, (s, e) => s + e.carbsG);
    final totalFat = dayEntries.fold<double>(0, (s, e) => s + e.fatG);
    items
      ..add(
        _DayHeader(
          day,
          totalKcal,
          dayEntries.length,
          totalProtein,
          totalCarbs,
          totalFat,
        ),
      )
      ..addAll(dayEntries.map(_EntryRow.new));
  }
  return items;
}

String _dateRangeLabel(DateTimeRange r) =>
    '${r.start.toString().substring(0, 10)}'
    ' – ${r.end.toString().substring(0, 10)}';

String _formatDay(String dateKey) {
  try {
    final d = DateTime.parse(dateKey);
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${wd[d.weekday - 1]} ${d.day} ${mo[d.month - 1]} ${d.year}';
  } on Exception {
    return dateKey;
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// Shows every non-deleted logged entry, grouped by day, with optional
/// filtering and sorting.
class HistoryScreen extends StatefulWidget {
  /// Creates a [HistoryScreen].
  ///
  /// [initialDateRange], when given, pre-applies a date-range filter (e.g.
  /// the Calendar screen navigating here after a day is tapped, filtering
  /// to just that one day).
  const HistoryScreen({this.initialDateRange, super.key});

  /// A date-range filter applied on first load; null shows everything.
  final DateTimeRange? initialDateRange;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<FoodEntry>? _allEntries;
  List<FoodEntry> _displayed = const [];
  late HistoryFilter _filter;
  HistorySortField _sortField = HistorySortField.date;
  bool _sortAscending = false;

  @override
  void initState() {
    super.initState();
    _filter = HistoryFilter(dateRange: widget.initialDateRange);
    unawaited(_load());
  }

  Future<void> _load() async {
    final entries = await LogStorageService.instance.allEntriesNewestFirst();
    if (!mounted) return;
    setState(() {
      _allEntries = entries;
      _displayed = applyHistoryFilter(
        entries,
        _filter,
        _sortField,
        ascending: _sortAscending,
      );
    });
  }

  Future<void> _onEditEntry(FoodEntry entry) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => EditEntryScreen(entry: entry)),
    );
    await _load();
  }

  void _applyFilterSort() {
    setState(() {
      _displayed = applyHistoryFilter(
        _allEntries!,
        _filter,
        _sortField,
        ascending: _sortAscending,
      );
    });
  }

  Future<void> _openFilterSheet() async {
    final all = _allEntries!;
    final maxKcal = all.isEmpty
        ? 2000.0
        : all.map((e) => e.kcal).reduce((a, b) => a > b ? a : b);
    final maxProtein = all.isEmpty
        ? 200.0
        : all.map((e) => e.proteinG).reduce((a, b) => a > b ? a : b);
    final maxCarbs = all.isEmpty
        ? 200.0
        : all.map((e) => e.carbsG).reduce((a, b) => a > b ? a : b);
    final maxFat = all.isEmpty
        ? 100.0
        : all.map((e) => e.fatG).reduce((a, b) => a > b ? a : b);

    var draft = HistoryFilter(
      nameQuery: _filter.nameQuery,
      dateRange: _filter.dateRange,
      minKcal: _filter.minKcal,
      maxKcal: _filter.maxKcal,
      minProtein: _filter.minProtein,
      maxProtein: _filter.maxProtein,
      minCarbs: _filter.minCarbs,
      maxCarbs: _filter.maxCarbs,
      minFat: _filter.minFat,
      maxFat: _filter.maxFat,
      hasPhoto: _filter.hasPhoto,
      source: _filter.source,
    );
    var draftSortField = _sortField;
    var draftSortAscending = _sortAscending;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => _FilterSheet(
          filter: draft,
          sortField: draftSortField,
          ascending: draftSortAscending,
          maxKcal: maxKcal,
          maxProtein: maxProtein,
          maxCarbs: maxCarbs,
          maxFat: maxFat,
          onFilterChanged: (f) => setSheet(() => draft = f),
          onSortChanged: ({required field, required asc}) {
            setSheet(() {
              draftSortField = field;
              draftSortAscending = asc;
            });
          },
          onApply: () {
            setState(() {
              _filter = draft;
              _sortField = draftSortField;
              _sortAscending = draftSortAscending;
            });
            _applyFilterSort();
            Navigator.of(ctx).pop();
          },
          onClear: () {
            setSheet(() {
              draft = HistoryFilter();
              draftSortField = HistorySortField.date;
              draftSortAscending = false;
            });
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allEntries = _allEntries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (allEntries != null)
            Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.filter_list),
                  tooltip: 'Filter & sort',
                  onPressed: _openFilterSheet,
                ),
                if (_filter.isActive)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: allEntries == null
          ? const Center(child: CircularProgressIndicator())
          : _displayed.isEmpty
          ? Center(
              child: Text(
                allEntries.isEmpty
                    ? 'Nothing logged yet.'
                    : 'No entries match the current filter.',
              ),
            )
          : _GroupedList(
              items: _buildGroupedItems(_displayed),
              onDeleteEntry: _load,
              onEditEntry: _onEditEntry,
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grouped list widget
// ---------------------------------------------------------------------------

class _GroupedList extends StatelessWidget {
  const _GroupedList({
    required this.items,
    required this.onDeleteEntry,
    required this.onEditEntry,
  });
  final List<_HistoryItem> items;
  final Future<void> Function() onDeleteEntry;
  final Future<void> Function(FoodEntry) onEditEntry;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return switch (item) {
          _DayHeader() => _DayHeaderTile(item),
          _EntryRow() => _EntryTile(
            item.entry,
            onDelete: onDeleteEntry,
            onEdit: () => onEditEntry(item.entry),
          ),
        };
      },
    );
  }
}

class _DayHeaderTile extends StatelessWidget {
  const _DayHeaderTile(this.header);
  final _DayHeader header;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final goal = AppSettingsService.dailyKcalGoal;
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
                  _formatDay(header.dateKey),
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

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.entry, {this.onDelete, this.onEdit});
  final FoodEntry entry;

  /// Called after a confirmed delete so the parent can reload.
  final Future<void> Function()? onDelete;

  /// Called when the tile is tapped to open the edit screen.
  final Future<void> Function()? onEdit;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _Thumbnail(imagePath: entry.imagePath),
      title: Text(entry.desc),
      subtitle: Text('${entry.time}  •  ${entry.source}'),
      trailing: Text('${entry.kcal.toStringAsFixed(0)} kcal'),
      // Any entry can be edited (legacy null-id entries gain a UUID on save).
      // Delete remains id-only to avoid ambiguous time+desc matches.
      onTap: () => onEdit?.call(),
      onLongPress: entry.id != null ? () => _confirmDelete(context) : null,
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

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.imagePath});

  final String? imagePath;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    if (path == null) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Icon(Icons.restaurant),
      );
    }
    return GestureDetector(
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => PhotoViewerScreen(path: path)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(path),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => const SizedBox(
            width: 40,
            height: 40,
            child: Icon(Icons.broken_image),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filter sheet
// ---------------------------------------------------------------------------

class _FilterSheet extends StatelessWidget {
  const _FilterSheet({
    required this.filter,
    required this.sortField,
    required this.ascending,
    required this.maxKcal,
    required this.maxProtein,
    required this.maxCarbs,
    required this.maxFat,
    required this.onFilterChanged,
    required this.onSortChanged,
    required this.onApply,
    required this.onClear,
  });

  final HistoryFilter filter;
  final HistorySortField sortField;
  final bool ascending;
  final double maxKcal;
  final double maxProtein;
  final double maxCarbs;
  final double maxFat;
  final void Function(HistoryFilter) onFilterChanged;
  final void Function({
    required HistorySortField field,
    required bool asc,
  })
  onSortChanged;
  final VoidCallback onApply;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Filter & Sort',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: onClear,
                  child: const Text('Clear all'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Name search
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search by name',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    controller: TextEditingController(text: filter.nameQuery)
                      ..selection = TextSelection.collapsed(
                        offset: filter.nameQuery.length,
                      ),
                    onChanged: (v) {
                      filter.nameQuery = v;
                      onFilterChanged(filter);
                    },
                  ),
                  const SizedBox(height: 16),

                  // Date range
                  Text(
                    'Date range',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      filter.dateRange == null
                          ? 'Any date'
                          : _dateRangeLabel(filter.dateRange!),
                    ),
                    onPressed: () async {
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                        initialDateRange: filter.dateRange,
                      );
                      if (picked != null) {
                        filter.dateRange = picked;
                        onFilterChanged(filter);
                      }
                    },
                  ),
                  if (filter.dateRange != null)
                    TextButton(
                      onPressed: () {
                        filter.dateRange = null;
                        onFilterChanged(filter);
                      },
                      child: const Text('Clear date range'),
                    ),
                  const SizedBox(height: 16),

                  // Kcal range
                  if (maxKcal > 0) ...[
                    Text(
                      'Kcal range',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    _SliderEndpointLabels(
                      lo: '0',
                      hi: maxKcal.round().toString(),
                    ),
                    RangeSlider(
                      key: const Key('kcal-range-slider'),
                      max: maxKcal,
                      values: RangeValues(
                        filter.minKcal ?? 0,
                        filter.maxKcal ?? maxKcal,
                      ),
                      labels: RangeLabels(
                        (filter.minKcal ?? 0).toStringAsFixed(0),
                        (filter.maxKcal ?? maxKcal).toStringAsFixed(0),
                      ),
                      onChanged: (v) {
                        filter.minKcal = v.start > 0 ? v.start : null;
                        filter.maxKcal = v.end < maxKcal ? v.end : null;
                        onFilterChanged(filter);
                      },
                    ),
                    _SliderSelectedLabel(
                      '${(filter.minKcal ?? 0).round()}'
                      ' – ${(filter.maxKcal ?? maxKcal).round()} kcal',
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Protein range
                  if (maxProtein > 0) ...[
                    Text(
                      'Protein range (g)',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    _SliderEndpointLabels(
                      lo: '0',
                      hi: '${maxProtein.round()}g',
                    ),
                    RangeSlider(
                      key: const Key('protein-range-slider'),
                      max: maxProtein,
                      values: RangeValues(
                        filter.minProtein ?? 0,
                        filter.maxProtein ?? maxProtein,
                      ),
                      labels: RangeLabels(
                        (filter.minProtein ?? 0).toStringAsFixed(0),
                        (filter.maxProtein ?? maxProtein).toStringAsFixed(0),
                      ),
                      onChanged: (v) {
                        filter.minProtein = v.start > 0 ? v.start : null;
                        filter.maxProtein = v.end < maxProtein ? v.end : null;
                        onFilterChanged(filter);
                      },
                    ),
                    _SliderSelectedLabel(
                      '${(filter.minProtein ?? 0).round()}'
                      ' – ${(filter.maxProtein ?? maxProtein).round()}g',
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Carbs range
                  if (maxCarbs > 0) ...[
                    Text(
                      'Carbs range (g)',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    _SliderEndpointLabels(
                      lo: '0',
                      hi: '${maxCarbs.round()}g',
                    ),
                    RangeSlider(
                      key: const Key('carbs-range-slider'),
                      max: maxCarbs,
                      values: RangeValues(
                        filter.minCarbs ?? 0,
                        filter.maxCarbs ?? maxCarbs,
                      ),
                      labels: RangeLabels(
                        (filter.minCarbs ?? 0).toStringAsFixed(0),
                        (filter.maxCarbs ?? maxCarbs).toStringAsFixed(0),
                      ),
                      onChanged: (v) {
                        filter.minCarbs = v.start > 0 ? v.start : null;
                        filter.maxCarbs = v.end < maxCarbs ? v.end : null;
                        onFilterChanged(filter);
                      },
                    ),
                    _SliderSelectedLabel(
                      '${(filter.minCarbs ?? 0).round()}'
                      ' – ${(filter.maxCarbs ?? maxCarbs).round()}g',
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Fat range
                  if (maxFat > 0) ...[
                    Text(
                      'Fat range (g)',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    _SliderEndpointLabels(
                      lo: '0',
                      hi: '${maxFat.round()}g',
                    ),
                    RangeSlider(
                      key: const Key('fat-range-slider'),
                      max: maxFat,
                      values: RangeValues(
                        filter.minFat ?? 0,
                        filter.maxFat ?? maxFat,
                      ),
                      labels: RangeLabels(
                        (filter.minFat ?? 0).toStringAsFixed(0),
                        (filter.maxFat ?? maxFat).toStringAsFixed(0),
                      ),
                      onChanged: (v) {
                        filter.minFat = v.start > 0 ? v.start : null;
                        filter.maxFat = v.end < maxFat ? v.end : null;
                        onFilterChanged(filter);
                      },
                    ),
                    _SliderSelectedLabel(
                      '${(filter.minFat ?? 0).round()}'
                      ' – ${(filter.maxFat ?? maxFat).round()}g',
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Photo filter
                  Text(
                    'Photo',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('Any'),
                        selected: filter.hasPhoto == null,
                        onSelected: (_) {
                          filter.hasPhoto = null;
                          onFilterChanged(filter);
                        },
                      ),
                      FilterChip(
                        label: const Text('With photo'),
                        selected: filter.hasPhoto == true,
                        onSelected: (_) {
                          filter.hasPhoto = true;
                          onFilterChanged(filter);
                        },
                      ),
                      FilterChip(
                        label: const Text('Without photo'),
                        selected: filter.hasPhoto == false,
                        onSelected: (_) {
                          filter.hasPhoto = false;
                          onFilterChanged(filter);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Source filter
                  Text(
                    'Source',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('All'),
                        selected: filter.source == null,
                        onSelected: (_) {
                          filter.source = null;
                          onFilterChanged(filter);
                        },
                      ),
                      for (final src in ['manual', 'food bank', 'meal'])
                        FilterChip(
                          label: Text(src),
                          selected: filter.source == src,
                          onSelected: (_) {
                            filter.source = src;
                            onFilterChanged(filter);
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Sort
                  Text(
                    'Sort by',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButton<HistorySortField>(
                          isExpanded: true,
                          value: sortField,
                          items: const [
                            DropdownMenuItem(
                              value: HistorySortField.date,
                              child: Text('Date'),
                            ),
                            DropdownMenuItem(
                              value: HistorySortField.kcal,
                              child: Text('Kcal'),
                            ),
                            DropdownMenuItem(
                              value: HistorySortField.protein,
                              child: Text('Protein'),
                            ),
                            DropdownMenuItem(
                              value: HistorySortField.carbs,
                              child: Text('Carbs'),
                            ),
                            DropdownMenuItem(
                              value: HistorySortField.fat,
                              child: Text('Fat'),
                            ),
                            DropdownMenuItem(
                              value: HistorySortField.description,
                              child: Text('Description'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) {
                              onSortChanged(field: v, asc: ascending);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          ascending ? Icons.arrow_upward : Icons.arrow_downward,
                        ),
                        tooltip: ascending ? 'Ascending' : 'Descending',
                        onPressed: () =>
                            onSortChanged(field: sortField, asc: !ascending),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onApply,
                child: const Text('Apply'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Slider label helpers
// ---------------------------------------------------------------------------

/// Thin row showing the min (0) and max endpoint values for a range slider.
class _SliderEndpointLabels extends StatelessWidget {
  const _SliderEndpointLabels({required this.lo, required this.hi});
  final String lo;
  final String hi;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Row(
      children: [
        Text(lo, style: style),
        const Spacer(),
        Text(hi, style: style),
      ],
    );
  }
}

/// Centred text showing the currently-selected range value (always visible).
class _SliderSelectedLabel extends StatelessWidget {
  const _SliderSelectedLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
