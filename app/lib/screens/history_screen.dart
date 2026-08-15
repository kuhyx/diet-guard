/// Logged meal history with day grouping, filtering, and sorting.
///
/// The filter model, the grouped list and the filter sheet live in
/// `lib/widgets/history/` (split for the repo's 250-line cap); this file is the
/// screen that wires them together and owns the filter state.
library;

import 'dart:async';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/edit_entry_screen.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:diet_guard_app/widgets/history/history_filter.dart';
import 'package:diet_guard_app/widgets/history/history_filter_sheet.dart';
import 'package:diet_guard_app/widgets/history/history_grouping.dart';
import 'package:diet_guard_app/widgets/history/history_list.dart';
import 'package:flutter/material.dart';

/// Logged meal history: every entry, grouped by day, filterable and sortable.
///
/// Owns the live [HistoryFilter] and sort order; the sheet that edits them and
/// the list that renders the result are separate widgets under
/// `lib/widgets/history/`.
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
      source: _filter.source,
    );
    var draftSortField = _sortField;
    var draftSortAscending = _sortAscending;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => FilterSheet(
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
          : GroupedList(
              items: buildGroupedItems(_displayed),
              onDeleteEntry: _load,
              onEditEntry: _onEditEntry,
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grouped list widget
// ---------------------------------------------------------------------------
